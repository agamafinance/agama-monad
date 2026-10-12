import type { Config } from 'tailwindcss';

const config: Config = {
  content: ['./app/**/*.{ts,tsx}', './components/**/*.{ts,tsx}'],
  darkMode: 'class',
  theme: {
    extend: {
      colors: {
        bg: '#254839',
        panel: '#fdf8ed',
        surface: '#f6efde',
        surface2: '#ede5cf',
        border: 'rgba(8,25,18,0.12)',
        borderStrong: 'rgba(8,25,18,0.22)',
        fg: {
          DEFAULT: '#254839',
          muted: '#48685A',
          dim: '#70B19E',
        },
        brand: {
          DEFAULT: '#254839',
          600: '#1F3D31',
          700: '#14271F',
        },
      },
      fontFamily: {
        sans: ['var(--font-sans)', 'system-ui', 'sans-serif'],
      },
      boxShadow: {
        pill: 'inset 0 0 0 1px rgba(255,255,255,0.06)',
      },
      backgroundImage: {
        'gradient-frame':
          'linear-gradient(135deg, #4F6BFF 0%, #7B3FE4 50%, #2A2F55 100%)',
        'gradient-btn':
          'linear-gradient(180deg, #6B8BFF 0%, #2E58E8 100%)',
        'gradient-pill':
          'linear-gradient(180deg, rgba(27,32,50,0.9), rgba(13,16,26,0.9))',
      },
    },
  },
  plugins: [],
};

export default config;
