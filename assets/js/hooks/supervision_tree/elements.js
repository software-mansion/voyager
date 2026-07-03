/**
 * @typedef {Object} Info
 * @property {string|any[]} registered_name
 *
 * @typedef {Object} ServerNode
 * @property {string} key
 * @property {string|null} parent_key
 * @property {string|null} pid "<X.Y.Z>" (null for ghost children)
 * @property {string|any[]} name
 * @property {'app'|'supervisor'|'worker'|'port'|'reference'} type
 * @property {number} child_count
 * @property {Info|'dead'|null} info
 * @property {string[]|'not_loaded'} children_keys
 */

/**
 * @typedef {Object} ServerEdge
 * @property {string} id
 * @property {string} source
 * @property {string} target
 * @property {'link'|'monitor'|'monitored_by'} kind
 */

/**
 * @param {string} key
 * @param {ServerNode} node
 */
export function elementsFor(key, node) {
  const child_count = node.child_count ?? 0;
  const children_keys =
    node.children_keys === 'not_loaded' ? null : node.children_keys;

  const data = {
    id: key,
    name: node.name,
    type: node.type,
    info: node.info,
    child_count: child_count,
    parent_key: node.parent_key,
    children_keys: children_keys,
    dead: node.info === 'dead',
    is_collapsed: initialIsCollapsedState({ child_count, children_keys }),
    is_from_relation: node.parent_key === null,
  };
  data.displayLabel = composeLabel(data);

  const els = [{ group: 'nodes', data }];

  if (node.parent_key) {
    els.push({
      group: 'edges',
      data: {
        id: edgeId(node.parent_key, key),
        source: node.parent_key,
        target: key,
      },
    });
  }

  return els;
}

/**
 * @param {ServerEdge} edge
 */
export function relEdgeElement(edge) {
  return {
    group: 'edges',
    data: {
      id: edge.id,
      source: edge.source,
      target: edge.target,
      kind: edge.kind,
    },
    classes: `rel ${edge.kind}`,
  };
}

/**
 * @param {{child_count:number,children_keys:string[]|'not_loaded'|null}} data
 */
export function initialIsCollapsedState({ child_count, children_keys }) {
  return (
    child_count > 0 &&
    (children_keys === 'not_loaded' || children_keys === null)
  );
}

// The label is the process's registered name, or its pid when unregistered —
// the server resolves this into `name`. Nodes with children also show their
// direct child count as `(N)`.
export function composeLabel(d) {
  const name = formatName(d.name);
  if (d.type === 'worker' || d.child_count === 0) {
    return name;
  }
  return `${name} (${d.child_count})`;
}

export function formatName(name) {
  if (name === null || name === undefined) return '';
  if (Array.isArray(name)) return name.map(formatName).join(':');
  if (typeof name === 'string') return name;
  return String(name);
}

export function edgeId(parentKey, childKey) {
  return `e:${parentKey}->${childKey}`;
}

export function isRealPid(key) {
  const re = /^<\d+\.\d+\.\d+>$/;
  return re.test(key);
}

/**
 * Calculates whether toggle expand button should be rendered based on it's node and zoom level
 */

export function overlayButtonIntersectsExtent(node, extent, zoomLevel) {
  const bb = node.boundingBox();
  return !(
    bb.x2 < extent.x1 ||
    bb.x2 + 40 / zoomLevel > extent.x2 ||
    bb.y1 < extent.y1 ||
    bb.y2 > extent.y2
  );
}
