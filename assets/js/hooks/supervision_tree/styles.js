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
          'background-color, border-color, border-width, opacity, text-opacity',
        'transition-duration': '80ms',
        'transition-timing-function': 'ease-out',
      },
    },
    {
      selector: 'node.hover',
      style: {
        'background-color': t.primary,
        'border-color': t.primary,
        'text-background-opacity': 0,
        'text-opacity': 0.1,
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
      selector: 'node[type = "port"]',
      style: {
        shape: 'triangle',
        'border-color': t.port,
        width: 14,
        height: 14,
      },
    },
    {
      selector: 'node[type = "port"].hover',
      style: {
        'background-color': t.port,
      },
    },
    {
      selector: 'node[type = "reference"]',
      style: {
        shape: 'rectangle',
        'border-color': t.reference,
        width: 12,
        height: 12,
      },
    },
    {
      selector: 'node[type = "reference"].hover',
      style: {
        'background-color': t.reference,
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
      selector: 'edge',
      style: {
        'curve-style': 'unbundled-bezier',

        'control-point-distances': function (edge) {
          const tension = getTensionForEdge(edge);
          const { dx, dy } = getSourceTargetDelta(edge);

          const length = Math.sqrt(dx * dx + dy * dy);
          if (length === 0) return [0, 0];

          const dist = (tension * (dx * dy)) / length;
          return [-dist, dist];
        },
        'control-point-weights': function (edge) {
          const tension = getTensionForEdge(edge);
          const { dx, dy } = getSourceTargetDelta(edge);

          const lengthSq = dx * dx + dy * dy;
          if (lengthSq === 0) return [0.5, 0.5];

          const w1 = (tension * dx * dx) / lengthSq;
          const w2 = ((1 - tension) * dx * dx + dy * dy) / lengthSq;

          return [w1, w2];
        },
        'line-color': t.base500,
        width: 1.4,
        'transition-property':
          'line-color, target-arrow-color, width, opacity, arrow-scale',
        'transition-duration': '80ms',
        'transition-timing-function': 'ease-out',
      },
    },
    {
      // Relationship edges (link / monitor / monitored-by) are drawn as dashed,
      // directed overlays distinct from the solid structural supervision edges.
      selector: 'edge.rel',
      style: {
        'line-style': 'dashed',
        width: 1.2,
        'target-arrow-shape': 'triangle',
        'z-index': 1,
        'line-dash-pattern': [6, 12],
      },
    },
    {
      selector: 'edge.link',
      style: {
        'line-color': t.base400,
        'target-arrow-shape': 'none',
      },
    },
    {
      selector: 'edge.monitor',
      style: {
        'line-color': t.processMonitor,
        'target-arrow-color': t.processMonitor,
        'line-dash-offset': 6,
      },
    },
    {
      selector: 'edge.monitored_by',
      style: {
        'line-color': t.processMonitoredBy,
        'target-arrow-color': t.processMonitoredBy,
        'line-dash-offset': 12,
      },
    },
    {
      selector: 'edge.hover',
      style: {
        width: 2.4,
        'arrow-scale': 1.25,
        'z-index': 15,
      },
    },
    {
      selector: 'edge.selected',
      style: {
        width: 4.5,
        opacity: 1,
        'z-index': 20,
      },
    },
    {
      selector: 'edge.supervision-link.selected',
      style: {
        'line-color': t.primary,
      },
    },
    {
      // Directed relationship edges: amplify the tip and add a mid-arrow so
      // direction stays readable when the tip sits under a right-side label.
      selector: 'edge.monitor.selected, edge.monitored_by.selected',
      style: {
        'arrow-scale': 2,
        'target-distance-from-node': 8,
        'mid-target-arrow-shape': 'triangle',
      },
    },
    {
      selector: 'edge.monitor.selected',
      style: {
        'mid-target-arrow-color': t.processMonitor,
      },
    },
    {
      selector: 'edge.monitored_by.selected',
      style: {
        'mid-target-arrow-color': t.processMonitoredBy,
      },
    },
    {
      selector: 'node.selected',
      style: {
        'background-color': t.primary,
        'border-color': t.primary,
        'border-width': 3,
        'text-opacity': 1,
        'font-weight': 600,
      },
    },
    {
      selector: 'node.selected.hover',
      style: {
        'background-color': t.primary,
        'border-color': t.primary,
        'text-background-opacity': 0,
        'text-opacity': 0.3,
      },
    },
    {
      selector: 'node.endpoint',
      style: {
        'border-color': t.primary,
        'border-width': 3,
        'font-weight': 600,
      },
    },
    {
      selector: 'node.endpoint.hover',
      style: {
        'background-color': t.primary,
        'border-color': t.primary,
        'text-background-opacity': 0,
        'text-opacity': 0.3,
      },
    },
    {
      selector: 'edge.dimmed',
      style: {
        opacity: 0.5,
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

/*
 * tension = how strongly the curve is pulled horizontally.
 * 0.5 = aggressive boxy S-curve
 * 0.25 to 0.35 = smooth, gentle sweep
 * 0.1 = almost a straight diagonal line
 */
function getTensionForEdge(edge) {
  const classNames = edge.classNames();

  if (classNames.includes('monitor')) {
    return 0.2;
  } else if (classNames.includes('monitored_by')) {
    return 0.4;
  }
  return 0.3;
}

function getSourceTargetDelta(edge) {
  const source = edge.source().position();
  const target = edge.target().position();
  const dx = target.x - source.x;
  const dy = target.y - source.y;
  return { dx, dy };
}
