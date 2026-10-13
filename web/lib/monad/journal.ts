'use client';

import {
  createSecretVaultWithExistingPasskey, createSecretVaultWithNewPasskey, decryptSecretVaultWithPasskey,
  isMeraError, parseSecretVault, type PasskeySecretVault,
} from '@category-labs/mera';
import { bytesToString, hexToBytes, stringToHex, type Address } from 'viem';

import { ADDR } from './config';
import { journalAbi } from './generated/abis';
import { remember, stored } from './passkey';
import { pub, send } from './useMonad';

/// The journal: what the user paid for each stock and why, the part of a
/// position the chain should never see. Mera seals it with the user's passkey
/// under a fresh PRF salt of its own (HKDF to AES-256-GCM), not the salt the
/// account key comes from, so the same passkey holds two unrelated secrets:
/// the key that signs and the key that reads this. Signing in leaks nothing
/// about the journal, and the journal key cannot sign anything.
///
/// The sealed vault lives on Monad (`AgamaJournal`), so any device the passkey
/// syncs to reads it back; the plaintext only ever exists in this tab.
export interface JournalEntry {
  id: string;
  at: number;
  /// A `StockKey`.
  asset: string;
  /// Decimal strings, as typed.
  qty: string;
  price: string;
  note: string;
}

export interface Journal {
  v: 1;
  entries: JournalEntry[];
}

export const emptyJournal = (): Journal => ({ v: 1, entries: [] });

/// What anyone sees on chain for `owner`: the sealed vault, or nothing.
export async function readSealed(owner: Address): Promise<PasskeySecretVault | undefined> {
  if (!ADDR.journal) return undefined;
  const raw = (await pub.readContract({
    address: ADDR.journal, abi: journalAbi, functionName: 'journalOf', args: [owner],
  })) as `0x${string}`;
  if (raw === '0x') return undefined;
  return parseSecretVault(bytesToString(hexToBytes(raw)));
}

/// One passkey prompt: the vault names its own credential and salt.
export async function unlock(vault: PasskeySecretVault): Promise<Journal> {
  try {
    const plain = await decryptSecretVaultWithPasskey({ rpId: window.location.hostname, vault });
    const j = JSON.parse(new TextDecoder().decode(plain)) as Journal;
    return j.v === 1 && Array.isArray(j.entries) ? j : emptyJournal();
  } catch (e) {
    throw new Error(journalErrorText(e));
  }
}

/// Seal `journal` with the passkey this browser knows (the one the account
/// signs with, when there is one), or a new one for a browser-wallet user, and
/// store it on Monad. One prompt, one transaction; returns the hash.
export async function sealAndStore(owner: Address, journal: Journal): Promise<`0x${string}`> {
  if (!ADDR.journal) throw new Error('The journal is not deployed on this network');
  const secret = new TextEncoder().encode(JSON.stringify(journal));
  const rpId = window.location.hostname;
  let vault: PasskeySecretVault;
  try {
    const known = stored();
    if (known) {
      vault = await createSecretVaultWithExistingPasskey({ rpId, credential: known as never, secret });
    } else {
      vault = await createSecretVaultWithNewPasskey({
        rp: { id: rpId, name: 'Agama' },
        user: { name: 'Agama journal', displayName: 'Agama journal' },
        secret,
      });
      remember(vault.credential.credentialId, vault.credential.transports);
    }
  } catch (e) {
    throw new Error(journalErrorText(e));
  }
  return send(owner, ADDR.journal, journalAbi, 'write', [stringToHex(JSON.stringify(vault))]);
}

function journalErrorText(e: unknown): string {
  if (!isMeraError(e)) return e instanceof Error ? e.message : 'The passkey did not answer';
  switch (e.code) {
    case 'DECRYPT_FAILED':
      return 'This passkey does not open this journal.';
    case 'PRF_UNAVAILABLE':
      return 'This passkey cannot derive a key. On desktop Chrome, save it to Google Password Manager, or use a phone or a security key.';
    case 'PASSKEY_OPERATION_FAILED':
      return 'The passkey prompt was closed. Try again.';
    default:
      return e.message;
  }
}
