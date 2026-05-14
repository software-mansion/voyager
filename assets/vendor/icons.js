const fs = require('fs');
const path = require('path');

module.exports = function ({ matchComponents, theme }) {
  const iconsDir = path.join(__dirname, '../css/icons');
  const values = {};

  fs.readdirSync(iconsDir).forEach((file) => {
    const name = path.basename(file, '.svg');
    values[name] = { name, fullPath: path.join(iconsDir, file) };
  });

  matchComponents(
    {
      icon: ({ name, fullPath }) => {
        const content = encodeURIComponent(
          fs
            .readFileSync(fullPath)
            .toString()
            .replace(/\r?\n|\r/g, '')
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
          width: theme('spacing.6'),
          height: theme('spacing.6'),
        };
      },
    },
    { values }
  );
};
