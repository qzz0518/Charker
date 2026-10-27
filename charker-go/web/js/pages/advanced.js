// 高级 (SettingsViews.swift AdvancedView). The Dock switch has no Windows
// counterpart and is left out; 在访达中显示 shows the log in File Explorer.

import { html, useEffect } from '../lib.js';
import { t } from '../core/l10n.js';
import { call, setActionMessage, setPrefs } from '../core/store.js';
import { ActionButton } from '../ui/components.js';
import { Segmented, SettingsGroup, SettingsPage, SliderRow, SwitchRow } from './settings.js';

const report = (err) => setActionMessage(String(err?.message || err));

export default function AdvancedPage({ state }) {
  const p = state.prefs;
  // AppModel.refreshLoginItemStatus: Task Manager can turn the entry off.
  useEffect(() => {
    call('RefreshLaunchAtLogin').catch(() => {});
  }, []);

  return html`<${SettingsPage} title=${t('高级')}>
    <${SettingsGroup} title=${t('外观')}>
      <div class="settings-row">
        <span class="t-body c-primary">${t('窗口外观')}</span>
        <${Segmented}
          label=${t('窗口外观')}
          value=${p.appearance}
          style=${{ width: '240px' }}
          segments=${[
            { title: t('跟随系统'), value: 'system' },
            { title: t('浅色'), value: 'light' },
            { title: t('深色'), value: 'dark' },
          ]}
          onChange=${(appearance) => setPrefs({ appearance }).catch(() => {})}
        />
      </div>
    </${SettingsGroup}>

    <${SettingsGroup} title=${t('常规')}>
      <${SwitchRow}
        title=${t('登录时启动')}
        on=${p.launchAtLogin}
        onChange=${(launchAtLogin) => setPrefs({ launchAtLogin }).catch(() => {})}
      />
      <${SliderRow}
        title=${t('轮询间隔')}
        value=${p.pollSeconds}
        min=${3}
        max=${20}
        unit="秒"
        onChange=${(pollSeconds) => setPrefs({ pollSeconds }).catch(() => {})}
      />
    </${SettingsGroup}>

    <${SettingsGroup} title=${t('测试')}>
      <${SwitchRow}
        title=${t('演示模式（模拟充电器）')}
        on=${p.demoMode}
        onChange=${(demoMode) => setPrefs({ demoMode }).catch(() => {})}
      />
    </${SettingsGroup}>

    <${SettingsGroup} title=${t('端口控制')}>
      <${SwitchRow}
        title=${t('允许端口开关')}
        on=${p.demoMode || p.writesEnabled}
        disabled=${p.demoMode}
        onChange=${(writesEnabled) => setPrefs({ writesEnabled }).catch(() => {})}
      />
    </${SettingsGroup}>

    <${SettingsGroup} title=${t('诊断')}>
      <${SwitchRow}
        title=${t('记录原始报文')}
        on=${p.captureRawPayloads}
        onChange=${(captureRawPayloads) => setPrefs({ captureRawPayloads }).catch(() => {})}
      />
      <div class="settings-actions">
        <${ActionButton}
          emphasis="primary"
          title=${t('导出诊断…')}
          onClick=${() => call('ExportDiagnostics').catch(report)}
        />
        <${ActionButton}
          title=${t('在资源管理器中显示')}
          onClick=${() => call('RevealDiagnosticsLog').catch(report)}
        />
      </div>
    </${SettingsGroup}>
  </${SettingsPage}>`;
}
