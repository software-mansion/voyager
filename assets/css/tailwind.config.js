// See the Tailwind configuration guide for advanced usage
// https://tailwindcss.com/docs/configuration
const plugin = require('tailwindcss/plugin');
const fs = require('fs');
const path = require('path');

module.exports = {
  darkMode: 'class',
  content: ['../js/**/*.js', '../../lib/**/*.ex'],
  theme: {
    extend: {
      colors: {
        // Backgrounds
        'app-bg':     'var(--bg-0)',
        'surface-bg': 'var(--bg-1)',
        'raised-bg':  'var(--bg-2)',
        'muted-bg':   'var(--bg-3)',
        // Borders
        'default-border': 'var(--border-default)',
        'strong-border':  'var(--border-strong)',
        // Text
        'primary-text':   'var(--text-0)',
        'secondary-text': 'var(--text-1)',
        'muted-text':     'var(--text-2)',
        'faint-text':     'var(--text-3)',
        // Brand
        'accent':      'var(--accent)',
        'accent-soft': 'var(--accent-soft)',
        // Semantic
        'good': 'var(--good)',
        'warn': 'var(--warn)',
        'bad':  'var(--bad)',
        'link': 'var(--link)',
      },
      fontFamily: {
        display: ['DM Sans', 'system-ui', 'sans-serif'],
        mono:    ['JetBrains Mono', 'ui-monospace', 'monospace'],
      },
      fontSize: {
        '2xs': ['11px', '16px'],
        '3xs': ['10px', '13px'],
      },
      boxShadow: {
        'accent-glow': '0 0 12px var(--accent-glow)',
        'card': 'var(--shadow-md)',
        'panel': 'var(--shadow-lg)',
      },
      keyframes: {
        fadeIn: {
          '0%':   { opacity: '0', transform: 'scale(0.95)' },
          '100%': { opacity: '1', transform: 'scale(1)' },
        },
        fadeOut: {
          '0%':   { opacity: '1', transform: 'scale(1)' },
          '100%': { opacity: '0', transform: 'scale(0.95)' },
        },
      },
      animation: {
        'fade-in':  'fadeIn 100ms ease-in forwards',
        'fade-out': 'fadeOut 200ms ease-out forwards',
      },
    },
  },
  plugins: [
    plugin(({ addVariant }) =>
      addVariant('phx-click-loading', ['&.phx-click-loading', '.phx-click-loading &'])
    ),
    plugin(({ addVariant }) =>
      addVariant('phx-submit-loading', ['&.phx-submit-loading', '.phx-submit-loading &'])
    ),
    plugin(({ addVariant }) =>
      addVariant('phx-change-loading', ['&.phx-change-loading', '.phx-change-loading &'])
    ),
    // Generates icon-{name} CSS mask classes from assets/css/icons/
    plugin(function ({ matchComponents, theme }) {
      const iconsDir = path.join(__dirname, './icons');
      const values = {};
      fs.readdirSync(iconsDir).forEach((file) => {
        const name = path.basename(file, '.svg');
        values[name] = { name, fullPath: path.join(iconsDir, file) };
      });
      matchComponents(
        {
          icon: ({ name, fullPath }) => {
            const content = encodeURIComponent(
              fs.readFileSync(fullPath).toString().replace(/\r?\n|\r/g, '')
            );
            return {
              [`--icon-${name}`]: `url('data:image/svg+xml;utf8,${content}')`,
              '-webkit-mask': `var(--icon-${name})`,
              mask: `var(--icon-${name})`,
              'mask-repeat': 'no-repeat',
              'mask-size': '100% 100%',
              'background-color': 'currentColor',
              'vertical-align': 'middle',
              display: 'inline-block',
              width: theme('spacing.4'),
              height: theme('spacing.4'),
            };
          },
        },
        { values }
      );
    }),
  ],
};
