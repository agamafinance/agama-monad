'use client';

import {
  createPasskeyWithPrfOutput, createSecp256k1SigningSession, getPasskeyPrfOutput, isMeraError,
  MeraError, type Secp256k1SigningSession, type WebAuthnClient,
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

export function stored(): { credentialId: string; transports?: string[] } | undefined {
  try {
    const raw = window.localStorage.getItem(STORED);
    return raw ? JSON.parse(raw) : undefined;
  } catch {
    return undefined;
  }
}

function open(prfOutput: Uint8Array): LocalAccount {
  session?.end();
  session = createSecp256k1SigningSession({ privateKey: deriveEvmKey(prfOutput) });
  return toViemAccount(session);
}

/// Asks the platform for a passkey of this site already on this device, with
/// Chrome's immediate UI mode (`uiMode: 'immediate'`, Chrome 149): when there
/// is none, it rejects at once and shows nothing, so a first visit goes
/// straight to creating one. Only the assertion goes through here; creation
/// keeps Mera's own client.
const immediateClient: WebAuthnClient = {
  createCredential: () => Promise.reject(new MeraError('PASSKEY_OPERATION_FAILED', 'not used')),
  async getCredential(request) {
    const credential = (await navigator.credentials.get({
      publicKey: {
        rpId: request.rpId,
        challenge: request.challenge,
        userVerification: request.userVerification,
        extensions: { prf: { eval: { first: request.prfSalt } } },
      },
      uiMode: 'immediate',
    } as CredentialRequestOptions)) as PublicKeyCredential | null;
    if (!credential) throw new MeraError('PASSKEY_OPERATION_FAILED', 'No passkey on this device');
    const first = credential.getClientExtensionResults().prf?.results?.first;
    return {
      credentialId: new Uint8Array(credential.rawId),
      ...(first ? { prfOutput: new Uint8Array(first as ArrayBuffer) } : {}),
    };
  },
};

async function immediateSupported(): Promise<boolean> {
  try {
    const caps = await (PublicKeyCredential as unknown as {
      getClientCapabilities?: () => Promise<Record<string, boolean>>;
    }).getClientCapabilities?.();
    return !!caps?.immediateGet;
  } catch {
    return false;
  }
}

export function remember(credentialId: string, transports?: readonly string[]) {
  window.localStorage.setItem(STORED, JSON.stringify({ credentialId, transports }));
}

async function create(): Promise<LocalAccount> {
  const created = await createPasskeyWithPrfOutput({
    rp: { id: window.location.hostname, name: 'Agama' },
    user: { name: 'Agama on Monad', displayName: 'Agama on Monad' },
  });
  remember(created.credentialId, created.transports);
  return open(created.prfOutput);
}

/// One button, three cases, one prompt each:
/// - this browser signed in before: that exact passkey, nothing to choose;
/// - the browser can tell whether a passkey exists here (immediate UI mode):
///   yours if there is one, else a new one, with no empty picker in between;
/// - it cannot (Safari, Firefox today): a new passkey.
export async function signInWithPasskey(): Promise<LocalAccount> {
  const rpId = window.location.hostname;
  try {
    const known = stored();
    if (known) {
      const { prfOutput, credentialId } = await getPasskeyPrfOutput({ rpId, credential: known as never });
      if (known.credentialId !== credentialId) remember(credentialId);
      return open(prfOutput);
    }
    if (await immediateSupported()) {
      try {
        const { prfOutput, credentialId } = await getPasskeyPrfOutput({ rpId, webAuthnClient: immediateClient });
        remember(credentialId);
        return open(prfOutput);
      } catch (e) {
        // No passkey here (or the user waved the sheet away): make one. A
        // passkey that answered without PRF is a real answer, not an absence.
        if (isMeraError(e) && e.code === 'PRF_UNAVAILABLE') throw e;
      }
    }
    return await create();
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
