"use client";

import { useEffect, useRef, useState } from 'react';
import { Navbar } from './Navbar';

export function AppFrame({ children }: { children: React.ReactNode }) {
  const scrollRef = useRef<HTMLDivElement>(null);
  const creamRef = useRef<HTMLDivElement>(null);
  const [thumb, setThumb] = useState<{
    top: number;
    height: number;
    creamRight: number;
  } | null>(null);
  const [visible, setVisible] = useState(false);
  const hideTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);

  useEffect(() => {
    const el = scrollRef.current;
    const cream = creamRef.current;
    if (!el || !cream) return;
    const recompute = () => {
      if (el.scrollHeight <= el.clientHeight + 1) {
        setThumb(null);
        return;
      }
      const TRACK_PADDING = 2;
      const vh = window.innerHeight;
      const trackHeight = vh - 2 * TRACK_PADDING;
      const ratio = el.clientHeight / el.scrollHeight;
      const thumbHeight = Math.max(40, trackHeight * ratio * 0.97);
      const thumbTop =
        TRACK_PADDING +
        (el.scrollTop / (el.scrollHeight - el.clientHeight)) * (trackHeight - thumbHeight);
      const creamRight = cream.getBoundingClientRect().right;
      setThumb({ top: thumbTop, height: thumbHeight, creamRight });
    };
    const onScroll = () => {
      recompute();
      setVisible(true);
      if (hideTimerRef.current) clearTimeout(hideTimerRef.current);
      hideTimerRef.current = setTimeout(() => setVisible(false), 500);
    };
    recompute();
    el.addEventListener('scroll', onScroll, { passive: true });
    window.addEventListener('resize', recompute);
    const ro = new ResizeObserver(recompute);
    ro.observe(el);
    return () => {
      el.removeEventListener('scroll', onScroll);
      window.removeEventListener('resize', recompute);
      ro.disconnect();
      if (hideTimerRef.current) clearTimeout(hideTimerRef.current);
    };
  }, []);

  return (
    <div className="h-screen flex flex-col">
      <Navbar />
      <div ref={creamRef} className="frame-panel md:rounded-[20px] flex-1 md:mx-[10.5px] md:mb-[10.5px] overflow-hidden">
        <div ref={scrollRef} className="h-full overflow-y-auto overflow-x-hidden no-scrollbar">
          <main>{children}</main>
        </div>
      </div>
      {thumb && (
        <div
          aria-hidden
          className={`hidden md:block fixed pointer-events-none z-50 transition-opacity duration-300 ease-out ${visible ? 'opacity-100' : 'opacity-0'}`}
          style={{
            top: 0,
            bottom: 0,
            left: thumb.creamRight,
            right: 0,
            paddingRight: '4px',
          }}
        >
          {/* margin: auto centers within (parent - paddingRight). Adding paddingRight on the
              right shifts the bar left to compensate for ~4 dev-px the browser eats on the
              right edge (overlay scrollbar reservation / window chrome). */}
          <div
            className="rounded-full bg-white/35"
            style={{
              position: 'absolute',
              top: thumb.top,
              height: thumb.height,
              width: '7.5px',
              left: 0,
              right: 0,
              marginLeft: 'auto',
              marginRight: 'auto',
            }}
          />
        </div>
      )}
    </div>
  );
}
