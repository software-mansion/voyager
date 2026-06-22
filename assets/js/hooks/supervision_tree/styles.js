import Color from 'colorjs.io';

export function buildStyle(t) {
  return [
    {
      selector: 'node',
      style: {
        shape: 'round-rectangle',
        width: 14,
        height: 14,
        'background-color': t.base100,
        'border-color': t.primary,
        'border-width': 2,
        label: 'data(displayLabel)',
        'text-halign': 'right',
        'text-valign': 'center',
        'text-margin-x': 6,
        'text-background-opacity': 1,
        'text-background-color': t.base100,
        'font-size': 11,
        'font-family': 'ui-monospace, SFMono-Regular, Menlo, monospace',
        color: t.baseContent,
        'overlay-padding': 8,
        'transition-property':
          'background-color, border-color, opacity, text-opacity',
        'transition-duration': '80ms',
        'transition-timing-function': 'ease-out',
      },
    },
    {
      selector: 'node.hover',
      style: {
        'background-color': t.primary,
        'border-color': t.primary,
      },
    },
    {
      selector: 'node[type = "worker"]',
      style: {
        shape: 'ellipse',
        'border-color': t.secondary,
        width: 14,
        height: 14,
      },
    },
    {
      selector: 'node[type = "worker"].hover',
      style: {
        'background-color': t.secondary,
      },
    },
    {
      selector: 'node[type = "app"]',
      style: {
        shape: 'round-diamond',
        width: 14,
        height: 14,
        'border-width': 3,
        color: t.baseContent,
      },
    },
    {
      selector: 'node[?dead]',
      style: {
        opacity: 0.4,
        'border-color': t.error,
      },
    },
    {
      selector: 'node.in-path',
      style: {
        'background-color': t.primary,
        'border-color': t.primary,
        'text-opacity': 1,
        'font-weight': 600,
      },
    },
    {
      selector: 'edge',
      style: {
        'curve-style': 'unbundled-bezier',

        'source-endpoint': 'outside-to-node-or-label',
        'target-endpoint': 'outside-to-node-or-label',

        // TENSION = how strongly the curve is pulled horizontally.
        // 0.5 = aggressive boxy S-curve
        // 0.25 to 0.35 = smooth, gentle sweep
        // 0.1 = almost a straight diagonal line
        'control-point-distances': function (edge) {
          const TENSION = 0.3;

          const source = edge.source().position();
          const target = edge.target().position();
          const dx = target.x - source.x;
          const dy = target.y - source.y;

          const length = Math.sqrt(dx * dx + dy * dy);
          if (length === 0) return [0, 0];

          const dist = (TENSION * (dx * dy)) / length;
          return [-dist, dist];
        },
        'control-point-weights': function (edge) {
          const TENSION = 0.3;

          const source = edge.source().position();
          const target = edge.target().position();
          const dx = target.x - source.x;
          const dy = target.y - source.y;

          const lengthSq = dx * dx + dy * dy;
          if (lengthSq === 0) return [0.5, 0.5];

          const w1 = (TENSION * dx * dx) / lengthSq;
          const w2 = ((1 - TENSION) * dx * dx + dy * dy) / lengthSq;

          return [w1, w2];
        },
        'line-color': t.base500,
        width: 1.4,
        'transition-property': 'line-color, width, opacity',
        'transition-duration': '80ms',
      },
    },
    {
      selector: 'edge.in-path',
      style: {
        'line-color': t.primary,
        width: 1.8,
        opacity: 1,
        'z-index': 10,
      },
    },
    {
      selector: '.hidden',
      style: { display: 'none' },
    },
  ];
}

export function toggleIcon(collapsed) {
  if (collapsed) {
    // plus
    return `<svg viewBox="0 0 12 12" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"><line x1="6" y1="2.5" x2="6" y2="9.5"/><line x1="2.5" y1="6" x2="9.5" y2="6"/></svg>`;
  }
  // minus
  return `<svg viewBox="0 0 12 12" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"><line x1="2.5" y1="6" x2="9.5" y2="6"/></svg>`;
}

export function getColor(cs, value, defaultColor = '') {
  const color = cs.getPropertyValue(value).trim();
  if (color) {
    return new Color(color).to('srgb').toString({ format: 'hex' });
  }
  return defaultColor;
}
