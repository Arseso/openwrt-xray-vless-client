// DOM helper: h('div', { class: 'x', onclick: fn }, 'text', child). Strings become text
// nodes, never HTML: names of servers and subscriptions come from the router.

type Attrs = Record<string, string | number | boolean | null | undefined | EventListener>;
export type Child = Node | string | number | null | undefined | false | Child[];

export function h<K extends keyof HTMLElementTagNameMap>(tag: K, attrs: Attrs = {}, ...children: Child[]): HTMLElementTagNameMap[K] {
  const el = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs)) {
    if (v == null || v === false)
      continue;
    if (k.startsWith('on') && typeof v === 'function')
      el.addEventListener(k.slice(2), v);
    else if (k in el && typeof v !== 'string')
      (el as unknown as Record<string, unknown>)[k] = v;
    else
      el.setAttribute(k, v === true ? '' : String(v));
  }
  append(el, children);
  return el;
}

function append(el: Node, children: Child[]): void {
  for (const c of children) {
    if (c == null || c === false)
      continue;
    if (Array.isArray(c))
      append(el, c);
    else
      el.appendChild(c instanceof Node ? c : document.createTextNode(String(c)));
  }
}

export function clear(el: Element, ...children: Child[]): void {
  el.replaceChildren();
  append(el, children);
}
