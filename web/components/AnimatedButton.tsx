'use client';

import { useState, useRef } from 'react';

type CommonProps = {
  children: React.ReactNode;
  className?: string;
  variant?: 'primary' | 'secondary';
  fillColor?: string;
  fillBackground?: string;
  fillBoxShadow?: string;
  borderColor?: string;
  textRestColor?: string;
  textHoverColor?: string;
};

type ButtonProps = CommonProps & {
  as?: 'button';
  type?: 'button' | 'submit';
  onClick?: () => void;
};

type AnchorProps = CommonProps & {
  as: 'a';
  href: string;
  target?: string;
  rel?: string;
};

type Props = ButtonProps | AnchorProps;

export default function AnimatedButton(props: Props) {
  const { children, className = '', variant = 'primary' } = props;
  const [hovered, setHovered] = useState(false);
  const timeoutRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const lockedRef = useRef(false);
  const insideRef = useRef(false);

  const handleEnter = () => {
    insideRef.current = true;
    if (lockedRef.current) return;
    if (timeoutRef.current) clearTimeout(timeoutRef.current);
    setHovered(true);
  };

  const handleLeave = () => {
    insideRef.current = false;
    if (timeoutRef.current) clearTimeout(timeoutRef.current);
    setHovered(false);
    lockedRef.current = true;
    timeoutRef.current = setTimeout(() => {
      lockedRef.current = false;
      if (insideRef.current) setHovered(true);
    }, 280);
  };

  const isPrimary = variant === 'primary';

  const fillColor = props.fillColor ?? (isPrimary ? '#254839' : '#fdf8ed');
  const borderColor = props.borderColor ?? (isPrimary ? '#254839' : '#fdf8ed');
  const textRest = props.textRestColor ?? '#fff';
  const textHover = props.textHoverColor ?? '#254839';

  const baseClass = `inline-flex items-center justify-center relative overflow-hidden rounded-full cursor-pointer text-center no-underline ${className}`;

  const inner = (
    <>
      <span
        aria-hidden
        className="absolute inset-0 rounded-full transition-transform duration-[250ms] ease-[cubic-bezier(0.4,0,0.2,1)]"
        style={{
          background: props.fillBackground ?? fillColor,
          boxShadow: props.fillBoxShadow,
          transform: isPrimary
            ? hovered
              ? 'translateY(110%)'
              : 'translateY(0)'
            : hovered
              ? 'translateY(0)'
              : 'translateY(110%)',
        }}
      />
      <span
        className="relative z-10 whitespace-nowrap transition-colors duration-[250ms] ease-[cubic-bezier(0.4,0,0.2,1)]"
        style={{ color: hovered ? textHover : textRest }}
      >
        {children}
      </span>
    </>
  );

  if (props.as === 'a') {
    return (
      <a
        href={props.href}
        target={props.target}
        rel={props.rel}
        className={baseClass}
        style={{ border: `1.5px solid ${borderColor}` }}
        onMouseEnter={handleEnter}
        onMouseLeave={handleLeave}
      >
        {inner}
      </a>
    );
  }

  return (
    <button
      type={props.type ?? 'button'}
      onClick={props.onClick}
      className={baseClass}
      style={{ border: `1.5px solid ${borderColor}` }}
      onMouseEnter={handleEnter}
      onMouseLeave={handleLeave}
    >
      {inner}
    </button>
  );
}
