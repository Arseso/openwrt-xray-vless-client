// Strings of the durations and ages (src/ui/format.ts).

import { strings } from '../core/i18n';

export const t = strings({
  en: {
    dh: '{d}d {h}h',
    hm: '{h}h {m}m',
    ms: '{m}m {s}s',
    s: '{s}s',
    ago: '{d} ago',
    never: 'never',
  },
  ru: {
    dh: '{d} д {h} ч',
    hm: '{h} ч {m} мин',
    ms: '{m} мин {s} с',
    s: '{s} с',
    ago: '{d} назад',
    never: 'никогда',
  },
});
