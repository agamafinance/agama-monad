'use client';

import {
  createPasskeyWithPrfOutput, createSecp256k1SigningSession, getPasskeyPrfOutput, isMeraError,
  type Secp256k1SigningSession,
} from '@category-labs/mera';
import { toViemAccount } from '@category-labs/mera/viem';
import { HDKey } from '@scure/bip32';
import { entropyToMnemonic, mnemonicToSeedSync } from '@scure/bip39';
import { wordlist } from '@scure/bip39/wordlists/english';
import type { LocalAccount } from 'viem';

/// Sign in with a passkey, through Mera: the passkey's PRF output is the root
/// of a plain EVM account (BIP-39 then BIP-44, `m/44'/60'/0'/0/0`), so there is
/// no extension, no seed phrase to write down and no custody backend. The key
/// lives in memory for the session and is zeroed on sign out.
///
/// Only the credential id is stored, and it holds no key material: it lets the
/// browser go straight to the same passkey next time.
const STORED = 'agama.monad.passkey';

let session: Secp256k1SigningSession | undefined;

function deriveEvmKey(prfOutput: Uint8Array): Uint8Array {
  const seed = mnemonicToSeedSync(entropyToMnemonic(prfOutput, wordlist));
  const node = HDKey.fromMasterSeed(seed).derive("m/44'/60'/0'/0/0");
  if (!node.privateKey) throw new Error('Could not derive an account from this passkey');
  return node.privateKey;
}

function stored(): { credentialId: string; transports?: string[] } | undefined {
  try {
    const raw = window.localStorage.getItem(STORED);
    return raw ? JSON.parse(raw) : undefined;
  } catch {
    return undefined;
  }
}

export function hasStoredPasskey(): boolean {
  return typeof window !== 'undefined' && !!stored();
}

function open(prfOutput: Uint8Array): LocalAccount {
  session?.end();
  session = createSecp256k1SigningSession({ privateKey: deriveEvmKey(prfOutput) });
  return toViemAccount(session);
}

/// The account behind the passkey this browser knows, or a new passkey when it
/// knows none. `existing` asks the platform for any saved passkey of this site
/// instead, which is how the same account is reached from another device.
export async function signInWithPasskey(existing = false): Promise<LocalAccount> {
  try {
    const known = stored();
    if (known || existing) {
      const { prfOutput, credentialId } = await getPasskeyPrfOutput({
        rpId: window.location.hostname,
        credential: known as never,
      });
      if (known?.credentialId !== credentialId) {
        window.localStorage.setItem(STORED, JSON.stringify({ credentialId }));
      }
      return open(prfOutput);
    }
    const created = await createPasskeyWithPrfOutput({
      rp: { id: window.location.hostname, name: 'Agama' },
      user: { name: 'Agama on Monad', displayName: 'Agama on Monad' },
    });
    window.localStorage.setItem(
      STORED,
      JSON.stringify({ credentialId: created.credentialId, transports: created.transports }),
    );
    return open(created.prfOutput);
  } catch (e) {
    throw new Error(passkeyErrorText(e));
  }
}

export function signOutPasskey() {
  session?.end();
  session = undefined;
}

function passkeyErrorText(e: unknown): string {
  if (!isMeraError(e)) return e instanceof Error ? e.message : 'The passkey did not answer';
  switch (e.code) {
    case 'PRF_UNAVAILABLE':
      return 'This passkey cannot derive an account. On desktop Chrome, save it to Google Password Manager (not the local profile), or use a phone or a security key.';
    case 'PASSKEY_OPERATION_FAILED':
      return 'The passkey prompt was closed. Try again.';
    case 'CRYPTO_UNAVAILABLE':
      return 'Passkeys need a secure page (https).';
    default:
      return e.message;
  }
}
