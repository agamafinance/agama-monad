'use client';

import { KeyRound, Lock, Plus, Trash2 } from 'lucide-react';
import { useEffect, useState } from 'react';
import type { PasskeySecretVault } from '@category-labs/mera';

import { TokenIcon } from '@/components/icons/TokenIcon';
import { NotDeployed } from '@/components/PriceBadge';
import { card, primaryBtn, secondaryBtn, Status, Step } from '@/components/monad/ui';
import { addressUrl, ADDR, STOCKS } from '@/lib/monad/config';
import { emptyJournal, readSealed, sealAndStore, unlock, type Journal, type JournalEntry } from '@/lib/monad/journal';
import { errorText, useMonadMarkets } from '@/lib/monad/useMonad';
import { useMonadWallet } from '@/lib/monad/WalletProvider';

const input =
  'h-11 w-full rounded-xl border border-[#254839]/15 bg-white/70 px-3 text-[14px] text-fg outline-none focus:border-[#254839]/45';

const money = (v: number) =>
  `${v < 0 ? '-' : ''}$${Math.abs(v).toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;

export default function MonadJournalPage() {
  const { address, kind, connect } = useMonadWallet();
  const { markets } = useMonadMarkets(address);

  /// What Monad holds for this wallet: `undefined` while reading, `null` for none.
  const [vault, setVault] = useState<PasskeySecretVault | null>();
  /// The plaintext, only once the passkey opened it (or when there is nothing to open).
  const [journal, setJournal] = useState<Journal>();
  const [dirty, setDirty] = useState(false);
  const [busy, setBusy] = useState(false);
  const [status, setStatus] = useState<{ text: string; hash?: string }>();
  const [draft, setDraft] = useState({ asset: 'TSLA', qty: '', price: '', note: '' });

  useEffect(() => {
    setVault(undefined); setJournal(undefined); setDirty(false); setStatus(undefined);
    if (!address) return;
    let alive = true;
    readSealed(address)
      .then((v) => {
        if (!alive) return;
        setVault(v ?? null);
        // Nothing sealed yet: nothing to open, start writing.
        if (!v) setJournal(emptyJournal());
      })
      .catch((e) => { if (alive) { setVault(null); setStatus({ text: errorText(e) }); } });
    return () => { alive = false; };
  }, [address]);

  const priceOf = (key: string) => {
    const m = markets.find((x) => x.stock.key === key);
    return m ? Number(m.price) / 1e18 : undefined;
  };

  async function open() {
    if (!vault) return;
    setBusy(true);
    setStatus({ text: 'Waiting for your passkey...' });
    try {
      setJournal(await unlock(vault));
      setStatus(undefined);
    } catch (e) {
      setStatus({ text: errorText(e) });
    } finally {
      setBusy(false);
    }
  }

  async function save() {
    if (!address || !journal) return;
    setBusy(true);
    setStatus({ text: 'Sealing with your passkey...' });
    try {
      const hash = await sealAndStore(address, journal);
      setVault(await readSealed(address) ?? null);
      setDirty(false);
      setStatus({ text: 'Sealed and stored on Monad. The chain holds ciphertext only.', hash });
    } catch (e) {
      setStatus({ text: errorText(e) });
    } finally {
      setBusy(false);
    }
  }

  function add() {
    if (!journal || !Number(draft.qty) || !Number(draft.price)) return;
    const entry: JournalEntry = { id: crypto.randomUUID(), at: Date.now(), ...draft };
    setJournal({ ...journal, entries: [entry, ...journal.entries] });
    setDraft({ ...draft, qty: '', price: '', note: '' });
    setDirty(true);
  }

  function remove(id: string) {
    if (!journal) return;
    setJournal({ ...journal, entries: journal.entries.filter((e) => e.id !== id) });
    setDirty(true);
  }

  const entries = journal?.entries ?? [];
  const cost = entries.reduce((t, e) => t + Number(e.qty) * Number(e.price), 0);
  const value = entries.reduce((t, e) => t + Number(e.qty) * (priceOf(e.asset) ?? Number(e.price)), 0);
  const sealedText = vault ? JSON.stringify(vault) : '';

  return (
    <>
      <section className="px-6 md:px-24 pt-10 md:pt-14 pb-8">
        <div className="max-w-[1400px] mx-auto">
          <h1 className="mt-3 text-[34px] md:text-[44px] leading-[1.05] text-fg font-semibold">My P&amp;L</h1>
          <p className="mt-4 max-w-[680px] text-[15px] text-fg-muted">
            Your position is public. What you paid, and why, is yours: sealed by your passkey, stored on Monad,
            readable only by you. Mera derives the key from your passkey, apart from the one your account signs
            with. Any device your passkey syncs to opens it; the chain, the explorer and Agama only ever see
            ciphertext.
          </p>
          <div className="mt-7 flex flex-wrap gap-8">
            <Stat label="Entries" value={journal ? String(entries.length) : vault ? 'Sealed' : '-'} />
            <Stat label="Cost basis" value={journal && entries.length ? money(cost) : '-'} sub="Only in this tab" />
            <Stat
              label="Unrealized"
              value={journal && entries.length ? `${value >= cost ? '+' : ''}${money(value - cost)}` : '-'}
              sub="Against the Chainlink price"
            />
            <Stat label="On Monad" value={vault ? `${sealedText.length} bytes` : '-'} sub="AES-256-GCM, passkey PRF" />
          </div>
        </div>
      </section>

      <section className="vault-panel relative z-10 rounded-t-[20px] px-6 md:px-24 pt-10 md:pt-14 pb-24">
        <div className="max-w-[1400px] mx-auto space-y-5">
          <NotDeployed />
          {!address ? (
            <div className={`${card} text-center`}>
              <p className="text-[15px] text-fg-muted">Sign in to open your journal. A passkey works best: one prompt does both.</p>
              <button
                type="button"
                onClick={() => connect('passkey')}
                className="mt-4 h-11 rounded-full bg-[#254839] px-6 text-[14px] font-medium text-[#fdf8ed] hover:bg-[#1F3D31]"
              >
                Sign in with a passkey
              </button>
            </div>
          ) : (
            <div className="grid gap-5 lg:grid-cols-[1.4fr_1fr]">
              <div className={card}>
                {!journal ? (
                  <div className="py-10 text-center">
                    <Lock className="mx-auto h-8 w-8 text-[#254839]" />
                    <p className="mt-3 text-[15px] text-fg">
                      {vault === undefined ? 'Reading Monad...' : 'Your journal is sealed.'}
                    </p>
                    {vault && (
                      <button type="button" onClick={open} disabled={busy} className={`${primaryBtn} mx-auto mt-5 max-w-[280px]`}>
                        {busy ? <Step text={status?.text} /> : 'Open with your passkey'}
                      </button>
                    )}
                  </div>
                ) : (
                  <>
                    <div className="flex items-center justify-between">
                      <h2 className="text-[13px] uppercase tracking-wider text-fg-muted">Your entries</h2>
                      {vault && (
                        <button
                          type="button"
                          onClick={() => { setJournal(undefined); setDirty(false); setStatus(undefined); }}
                          className="inline-flex items-center gap-1.5 text-[13px] text-fg-muted hover:text-fg"
                        >
                          <Lock className="h-3.5 w-3.5" /> Lock
                        </button>
                      )}
                    </div>

                    <div className="mt-4 grid gap-2 sm:grid-cols-[1fr_0.8fr_0.9fr]">
                      <select
                        className={input}
                        value={draft.asset}
                        onChange={(e) => setDraft({ ...draft, asset: e.target.value })}
                      >
                        {STOCKS.map((s) => <option key={s.key} value={s.key}>{s.base} · {s.name}</option>)}
                      </select>
                      <input
                        className={input}
                        inputMode="decimal"
                        placeholder="Quantity"
                        value={draft.qty}
                        onChange={(e) => setDraft({ ...draft, qty: e.target.value })}
                      />
                      <input
                        className={input}
                        inputMode="decimal"
                        placeholder={`Paid, per share${priceOf(draft.asset) ? ` (now $${priceOf(draft.asset)!.toFixed(2)})` : ''}`}
                        value={draft.price}
                        onChange={(e) => setDraft({ ...draft, price: e.target.value })}
                      />
                    </div>
                    <div className="mt-2 flex gap-2">
                      <input
                        className={input}
                        placeholder="Why (only you will ever read this)"
                        value={draft.note}
                        onChange={(e) => setDraft({ ...draft, note: e.target.value })}
                        onKeyDown={(e) => { if (e.key === 'Enter') add(); }}
                      />
                      <button
                        type="button"
                        onClick={add}
                        disabled={!Number(draft.qty) || !Number(draft.price)}
                        className="inline-flex h-11 shrink-0 items-center gap-1.5 rounded-full bg-[#254839]/[0.08] px-5 text-[14px] font-medium text-[#254839] hover:bg-[#254839]/[0.16] disabled:opacity-45"
                      >
                        <Plus className="h-4 w-4" /> Add
                      </button>
                    </div>

                    <div className="mt-5 space-y-2">
                      {entries.length === 0 && (
                        <p className="text-[14px] text-fg-muted">No entry yet. Add what you paid for a stock, then seal it.</p>
                      )}
                      {entries.map((e) => {
                        const st = STOCKS.find((s) => s.key === e.asset);
                        const now = priceOf(e.asset);
                        const pnl = now === undefined ? undefined : Number(e.qty) * (now - Number(e.price));
                        return (
                          <div key={e.id} className="flex items-center gap-3 rounded-xl bg-white/60 px-4 py-3">
                            <TokenIcon symbol={st?.base ?? e.asset} size={32} />
                            <div className="min-w-0">
                              <div className="text-[14px] font-medium text-fg">
                                {e.qty} {st?.base ?? e.asset} at ${Number(e.price).toFixed(2)}
                              </div>
                              <div className="truncate text-[12px] text-fg-muted">
                                {new Date(e.at).toLocaleDateString('en-US')}{e.note ? ` · ${e.note}` : ''}
                              </div>
                            </div>
                            <div className="ml-auto text-right">
                              <div className={`text-[14px] font-semibold tabular-nums ${pnl !== undefined && pnl < 0 ? 'text-[#a33a2a]' : 'text-fg'}`}>
                                {pnl === undefined ? '-' : `${pnl >= 0 ? '+' : ''}${money(pnl)}`}
                              </div>
                              <div className="text-[12px] text-fg-muted">{now ? `now $${now.toFixed(2)}` : ''}</div>
                            </div>
                            <button type="button" onClick={() => remove(e.id)} aria-label="Remove" className="text-fg-muted hover:text-fg">
                              <Trash2 className="h-4 w-4" />
                            </button>
                          </div>
                        );
                      })}
                    </div>

                    <button type="button" onClick={save} disabled={busy || !dirty} className={`${primaryBtn} mt-5`}>
                      {busy ? <Step text={status?.text} /> : vault ? 'Seal and update on Monad' : 'Seal and store on Monad'}
                    </button>
                  </>
                )}
                {!busy && <Status text={status?.text} hash={status?.hash} />}
              </div>

              <div className={card}>
                <h2 className="text-[13px] uppercase tracking-wider text-fg-muted">What Monad holds</h2>
                {vault ? (
                  <>
                    <pre
                      className="mt-3 max-h-[220px] overflow-hidden whitespace-pre-wrap break-all rounded-xl bg-[#254839] p-4 font-mono text-[11px] leading-[1.5] text-[#fdf8ed]/85"
                      data-testid="sealed"
                    >
                      {vault.ciphertext.slice(0, 600)}{vault.ciphertext.length > 600 ? '...' : ''}
                    </pre>
                    <dl className="mt-4 space-y-2 text-[13px]">
                      <Line label="Cipher" value="AES-256-GCM, key from the passkey PRF (HKDF)" />
                      <Line label="PRF salt" value={`${vault.prfSalt.slice(0, 16)}...`} mono />
                      <Line label="Passkey" value={`${vault.credential.credentialId.slice(0, 16)}...`} mono />
                      <Line label="Account key" value="Another salt, unrelated output" />
                    </dl>
                  </>
                ) : (
                  <p className="mt-3 text-[14px] text-fg-muted">Nothing yet. Once sealed, this is all anyone can read.</p>
                )}
                <div className="mt-5 flex items-start gap-2 rounded-xl bg-[#254839]/[0.06] p-3 text-[12px] text-fg-muted">
                  <KeyRound className="mt-0.5 h-4 w-4 shrink-0 text-[#254839]" />
                  <span>
                    {kind === 'passkey'
                      ? 'One passkey, two secrets: one salt derives the key that signs your transactions, another the key that seals this journal. Neither reveals the other.'
                      : 'Signed in with a browser wallet: the first seal makes a passkey for the journal alone. The wallet pays the transaction; the passkey holds the key.'}
                    {ADDR.journal && (
                      <>
                        {' '}
                        <a href={addressUrl(ADDR.journal)} target="_blank" rel="noreferrer" className="underline hover:text-fg">
                          AgamaJournal
                        </a>
                      </>
                    )}
                  </span>
                </div>
              </div>
            </div>
          )}
        </div>
      </section>
    </>
  );
}

function Stat({ label, value, sub }: { label: string; value: string; sub?: string }) {
  return (
    <div>
      <div className="text-[12px] uppercase tracking-wider text-fg-muted">{label}</div>
      <div className="text-[26px] font-semibold tabular-nums text-fg">{value}</div>
      {sub && <div className="text-[12px] text-fg-muted">{sub}</div>}
    </div>
  );
}

function Line({ label, value, mono }: { label: string; value: string; mono?: boolean }) {
  return (
    <div className="flex items-center justify-between gap-4">
      <dt className="text-fg-muted">{label}</dt>
      <dd className={`text-right text-fg ${mono ? 'font-mono text-[12px]' : ''}`}>{value}</dd>
    </div>
  );
}
