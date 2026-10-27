// About screen (#/about) — owner: web-screens.
//
// Identity card, version, plain-text links (the page has no network: buttons
// only explain where to open them), update row, third-party acknowledgements
// and the non-affiliation / license footnotes.

import {
  makeUI, h, clear, pageHead, actionButton, card, group, row, divider, chip,
} from './screens-util.js';

const LINKS = [
  { label: 'GH', title: '打开 Charker 的 GitHub 仓库', url: 'https://github.com/qzz0518/Charker' },
  { label: 'X', title: '在 X 上关注 @zerah_eth', url: 'https://x.com/zerah_eth' },
];

const LICENSES = [
  { name: 'Charker', meta: 'MIT', note: '界面与设计来源' },
  { name: 'three.js', meta: 'MIT', note: '三维模型渲染' },
  { name: 'Lucide', meta: 'ISC', note: '界面图标' },
  { name: 'Segoe UI Variable', meta: 'Windows', note: '系统字体' },
];

let instances = new Set();

export function render(root, state, ctx) {
  let inst = root.__scAbout;
  if (!inst) {
    inst = createAboutScreen(root);
    root.__scAbout = inst;
    instances.add(inst);
  }
  inst.update(makeUI(ctx, state), state);
}

export function cleanup() {
  for (const inst of instances) inst.dispose();
  instances.clear();
}

function createAboutScreen(root) {
  const screen = h('div', { class: 'sc-screen sc-about' });
  root.append(screen);

  let ui = null;
  let state = null;
  let builtLocale = null;
  let disposed = false;

  function build() {
    builtLocale = ui.locale;
    clear(screen);
    const version = (state && state.app && state.app.version) || '—';
    const dev = !!(state && state.app && state.app.dev);

    // Identity card.
    const identity = card('sc-about__identitycard',
      h('div', { class: 'sc-about__identity' },
        h('img', {
          class: 'sc-about__mark', src: './assets/app-icon.png', alt: '',
          width: '68', height: '68',
        }),
        h('div', { class: 'sc-about__names' },
          h('span', { class: 'sc-about__name', text: 'Charker' }),
          h('span', { class: 'sc-about__version ck-t-caption', text: ui.t('版本 %@', version) }),
          dev ? h('span', { class: 'sc-about__version ck-t-caption', text: ui.t('开发构建') }) : null),
        h('div', { class: 'sc-about__links' },
          ...LINKS.map((link) => h('button', {
            class: 'sc-linkbtn', type: 'button', title: ui.t(link.title),
            'aria-label': ui.t(link.title),
            onclick: () => ui.toast(ui.t('请在浏览器打开：%@', link.url), 'info'),
          }, link.label)))),
      h('p', { class: 'ck-t-caption sc-muted ck-u-cjk', text: ui.t('一个读取 Anker Prime 160W（A2687）充电数据的应用。') }),
      h('div', { class: 'sc-about__urls' },
        ...LINKS.map((link) => h('span', { text: `${ui.t(link.title)} — ${link.url}` }))));

    // Updates.
    const updates = group(ui, {
      footnote: '此版本不包含自动更新；请从 GitHub 获取新版本。',
    },
    row(ui, {
      title: '软件更新',
      sub: `Charker ${version}`,
      control: actionButton(ui, ui.t('检查更新…'), { disabled: true }),
    }));

    // Acknowledgements.
    const licenseCard = h('div', { class: 'ck-card sc-about__licenses' },
      ...LICENSES.map((entry, index) => h('div', { class: 'sc-about__license-row' },
        h('span', { class: 'sc-about__license-name', text: entry.name }),
        h('span', { class: 'sc-about__license-meta', text: ui.t(entry.note) }),
        chip(entry.meta, 'neutral'))));
    const licenses = h('section', { class: 'sc-group' },
      h('div', { class: 'sc-group__label' }, h('span', { class: 'ck-t-label', text: ui.t('致谢与许可') })),
      licenseCard);

    // Footnotes.
    const footnotes = h('div', { class: 'sc-about__footnotes' },
      h('p', { class: 'sc-about__foot ck-u-cjk', text: ui.t('独立项目，与 Anker 无关联、未获其背书。Anker、Anker Prime 为 Anker Innovations 的商标。') }),
      h('p', { class: 'sc-about__foot ck-u-cjk', text: ui.t('Charker 以 MIT 许可证发布；版权所有 © 2026 Charker 贡献者。') }),
      h('p', { class: 'sc-about__foot ck-u-cjk', text: ui.t('此 Windows 移植版基于 Go 与 WebView2，不包含 macOS 专属的 Apple 家庭 / Matter 功能。') }));

    screen.append(
      pageHead(ui, '关于 Charker'),
      identity,
      updates,
      licenses,
      footnotes);
  }

  function update(nextUi, nextState) {
    if (disposed) return;
    const localeChanged = builtLocale !== nextUi.locale;
    ui = nextUi;
    state = nextState || {};
    if (localeChanged || !screen.firstChild) build();
  }

  function dispose() {
    if (disposed) return;
    disposed = true;
    instances.delete(inst);
  }

  const inst = { update, dispose };
  return inst;
}
