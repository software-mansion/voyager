export function elementsFor(key, node) {
  const has_children = !!node['has_children?'];
  const children_keys =
    node.children_keys === 'not_loaded' ? null : node.children_keys;

  const data = {
    id: key,
    name: node.name,
    type: node.type,
    info: node.info,
    has_children,
    child_count: node.child_count ?? 0,
    parent_key: node.parent_key,
    children_keys:
      node.children_keys === 'not_loaded' ? null : node.children_keys,
    dead: node.info === 'dead',
    is_collapsed: has_children && children_keys === null,
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
    bb.x2 + 10 + 22 + 10 > extent.x2 ||
    bb.y1 < extent.y1 ||
    bb.y2 > extent.y2
  );
}
