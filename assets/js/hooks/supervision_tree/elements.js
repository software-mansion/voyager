/**
 * @typedef {Object} Info
 * @property {string|any[]} registered_name
 *
 * @typedef {Object} ServerNode
 * @property {string} key
 * @property {string|null} parent_key
 * @property {string|null} pid "<X.Y.Z>" (null for ghost children)
 * @property {string|any[]} name
 * @property {'app'|'supervisor'|'worker'} type
 * @property {number} child_count
 * @property {Info|'dead'|null} info
 * @property {string[]|'not_loaded'} children_keys
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
    child_count: node.child_count ?? 0,
    parent_key: node.parent_key,
    children_keys:
      node.children_keys === 'not_loaded' ? null : node.children_keys,
    dead: node.info === 'dead',
    is_collapsed: child_count > 0 && children_keys === null,
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

export function nodeIntersectsExtent(node, extent) {
  const bb = node.boundingBox();
  return !(
    bb.x2 < extent.x1 ||
    bb.x1 > extent.x2 ||
    bb.y2 < extent.y1 ||
    bb.y1 > extent.y2
  );
}
