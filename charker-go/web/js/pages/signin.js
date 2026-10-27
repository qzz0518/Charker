// AnkerSignInView.swift: an explicit Anker sign-in, either for the A2687
// owner id (purpose "ownerID") or for the A2345 cloud reader ("a2345"). The
// password and the code stay in this sheet; Go sends them once and keeps
// neither (service_account.go).

import { html, useEffect, useMemo, useRef, useState } from '../lib.js';
import { currentLocale, t, tf, tt } from '../core/l10n.js';
import { call } from '../core/store.js';
import { Icon, cx } from '../ui/components.js';

// AppModel.accountNickname: in memory only, like the Mac's.
let nickname = null;

/** The nickname of the last account signed in from this sheet, or null. */
export function accountNickname() {
  return nickname;
}

const isValidPhoneNumber = (v) => /^1\d{10}$/.test(v);
const isValidVerificationCode = (v) => /^\d{6}$/.test(v.trim());

let infoPromise = null;
function signInInfo() {
  infoPromise ??= call('AnkerSignInInfo').catch((err) => {
    infoPromise = null;
    throw err;
  });
  return infoPromise;
}

/** AnkerRegion.label: the localized country name and the Anker code. */
function regionLabel(region, names) {
  // The Swift table's names are the system's Chinese ones ("中国大陆",
  // "中国香港"); other languages ask the system.
  if (!names) return tf('%@（%@）', region.name, region.code);
  const code = region.code === 'UK' ? 'GB' : region.code === 'EL' ? 'GR' : region.code;
  let name = null;
  try {
    name = names?.of(code) ?? null;
  } catch {
    name = null;
  }
  return tf('%@（%@）', name && name !== code ? name : region.name, region.code);
}

function Spinner() {
  return html`<span class="dv-spinner si-spinner" aria-hidden="true"></span>`;
}

export default function SignInSheet({ state, purpose = 'ownerID', onClose }) {
  const [info, setInfo] = useState(null);
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [country, setCountry] = useState('');
  const [phone, setPhone] = useState('');
  const [code, setCode] = useState('');
  const [sentPhone, setSentPhone] = useState(null);
  const [sending, setSending] = useState(false);
  const [submitting, setSubmitting] = useState(false);
  const [resendAt, setResendAt] = useState(0);
  const [attempted, setAttempted] = useState(false);
  const [error, setError] = useState(null);
  const [now, setNow] = useState(Date.now());
  const generation = useRef(0);
  const fields = { email: useRef(null), password: useRef(null), phone: useRef(null), code: useRef(null) };

  const names = useMemo(() => {
    if (currentLocale() !== 'en') return null;
    try {
      return new Intl.DisplayNames(['en'], { type: 'region' });
    } catch {
      return null;
    }
  }, []);

  const isChina = country === 'CN';
  const normalizedPhone = phone.trim();
  const engineSigningIn = purpose === 'a2345' && !!state?.a2345?.signingIn;
  const isBusy = engineSigningIn || sending || submitting;
  const focus = (name) => setTimeout(() => fields[name].current?.focus());

  let validation = null;
  if (isChina) {
    if (!isValidPhoneNumber(normalizedPhone)) validation = t('请输入 11 位中国大陆手机号');
    else if (sentPhone !== normalizedPhone) validation = t('请先获取短信验证码');
    else if (!isValidVerificationCode(code)) validation = t('请输入 6 位短信验证码');
  } else {
    const address = email.trim();
    if (!address) validation = t('请输入邮箱');
    else if (!address.includes('@') || address.length < 5 || !address.includes('.')) validation = t('请输入有效的邮箱地址');
    else if (!password) validation = t('请输入密码');
    else if (country.length !== 2) validation = t('请选择国家或地区');
  }
  const canSubmit = validation == null && !isBusy;

  const cancelRequests = () => {
    generation.current += 1;
    call('CancelAnkerSignIn').catch(() => {});
    setSending(false);
    setSubmitting(false);
  };

  useEffect(() => {
    let live = true;
    signInInfo()
      .then((value) => {
        if (!live) return;
        setInfo(value);
        setCountry((c) => c || value.defaultCountry);
        focus(value.defaultCountry === 'CN' ? 'phone' : 'email');
      })
      .catch(() => {});
    return () => {
      live = false;
      // A slow login must not outlive the sheet and rebuild the session later.
      generation.current += 1;
      call('CancelAnkerSignIn').catch(() => {});
    };
  }, []);

  // The resend countdown ticks once a second while it runs.
  useEffect(() => {
    if (resendAt <= now) return undefined;
    const timer = setTimeout(() => setNow(Date.now()), 1000);
    return () => clearTimeout(timer);
  }, [resendAt, now]);
  const remaining = Math.max(0, Math.ceil((resendAt - now) / 1000));

  const changeCountry = (value) => {
    if (value === country) return;
    cancelRequests();
    setCountry(value);
    setCode('');
    setPassword('');
    setSentPhone(null);
    setAttempted(false);
    setError(null);
    focus(value === 'CN' ? 'phone' : 'email');
  };

  const changePhone = (value) => {
    if (value === phone) return;
    cancelRequests();
    setPhone(value);
    setCode('');
    setSentPhone(null);
    setAttempted(false);
    setError(null);
  };

  const sendCode = async () => {
    if (!isChina || isBusy || !isValidPhoneNumber(normalizedPhone) || resendAt > Date.now()) return;
    const target = normalizedPhone;
    const gen = generation.current;
    setSending(true);
    setError(null);
    // A cancelled or failed request cannot prove no SMS went out: reserve
    // the window before sending.
    setResendAt(Date.now() + 60000);
    setNow(Date.now());
    setCode('');
    setSentPhone(null);
    const result = await call('SendAnkerPhoneCode', target).catch(() => ({ ok: false }));
    if (generation.current !== gen) return;
    setSending(false);
    if (result?.ok) {
      setSentPhone(target);
      setResendAt(Date.now() + 60000);
      setNow(Date.now());
      focus('code');
    } else if (result?.error) {
      setError(result.error);
    }
  };

  const submit = async () => {
    setAttempted(true);
    if (!canSubmit) {
      if (isChina) {
        focus(isValidPhoneNumber(normalizedPhone) ? 'code' : 'phone');
      } else {
        const address = email.trim();
        focus(!address || !address.includes('@') || !address.includes('.') ? 'email' : 'password');
      }
      return;
    }
    const gen = generation.current;
    setSubmitting(true);
    setError(null);
    const request = isChina
      ? call('SignInAnkerPhone', purpose, normalizedPhone, code)
      : call('SignInAnker', purpose, email.trim(), password, country);
    const result = await request.catch(() => ({ ok: false }));
    if (generation.current !== gen) return;
    setSubmitting(false);
    if (result?.ok) {
      if (result.nickname) nickname = result.nickname;
      setPassword('');
      setCode('');
      onClose(true);
    } else if (result?.error) {
      setError(result.error);
      focus(isChina ? 'code' : 'password');
    }
  };

  const primaryAction = () => {
    if (isBusy) return;
    if (isChina && sentPhone !== normalizedPhone) {
      if (!isValidPhoneNumber(normalizedPhone)) {
        setAttempted(true);
        focus('phone');
      } else {
        sendCode();
      }
    } else {
      submit();
    }
  };

  const cancel = () => {
    cancelRequests();
    onClose(false);
  };

  // Return is the default button, Escape cancels.
  const keys = (e) => {
    if (e.key === 'Escape') {
      e.preventDefault();
      cancel();
    } else if (e.key === 'Enter' && !e.isComposing && e.target.tagName !== 'BUTTON' && e.target.tagName !== 'SELECT') {
      e.preventDefault();
      if (e.target === fields.email.current) focus('password');
      else if (e.target === fields.phone.current && sentPhone === normalizedPhone) focus('code');
      else if (e.target === fields.phone.current) primaryAction();
      else if (e.target === fields.code.current || e.target === fields.password.current) submit();
      else primaryAction();
    }
  };

  const field = (title, content) => html`<div class="si-field">
    <span class="t-body c-secondary si-field__label">${t(title)}</span>
    ${content}
  </div>`;

  const note = (text, symbol) => html`<div class="si-note">
    <${Icon} name=${symbol} class="si-note__icon" />
    <span class="t-caption c-tertiary para">${t(text)}</span>
  </div>`;

  const emailHint =
    attempted && (validation === t('请输入邮箱') || validation === t('请输入有效的邮箱地址'))
      ? validation
      : t('输入绑定 Anker 账号的邮箱');
  const passwordHint = attempted && validation === t('请输入密码') ? t('请输入密码') : t('输入 Anker 账号密码；密码不会保存');
  const primaryTitle = t(isChina && sentPhone !== normalizedPhone ? '获取验证码' : '登录');

  return html`<div class="dialog-backdrop dv-sheet-backdrop si-backdrop" onKeyDown=${keys}>
    <div class="dv-sheet si-sheet" role="dialog" aria-modal="true" aria-labelledby="si-title">
      <div class="si-header">
        <span id="si-title" class="t-title c-primary">${t(purpose === 'a2345' ? '连接 Anker Prime 250W' : '用 Anker 账号获取 ID')}</span>
        <span class="t-caption c-secondary para">${t('用绑定这台充电器的 Anker 账号登录。')}</span>
      </div>

      <div class="si-form">
        ${field(
          '国家或地区',
          html`<select
            class="field si-select"
            aria-label=${t('国家或地区')}
            value=${country}
            onChange=${(e) => changeCountry(e.currentTarget.value)}
          >
            ${info
              ? html`<optgroup label=${t('常用')}>
                    ${info.common.map((r) => html`<option value=${r.code}>${regionLabel(r, names)}</option>`)}
                  </optgroup>
                  <optgroup label=${t('其他')}>
                    ${info.others.map((r) => html`<option value=${r.code}>${regionLabel(r, names)}</option>`)}
                  </optgroup>`
              : null}
          </select>`,
        )}
        ${isChina
          ? html`${field(
              '手机号',
              html`<input
                ref=${fields.phone}
                class="field si-input"
                type="tel"
                autocomplete="tel"
                inputmode="numeric"
                placeholder="13800138000"
                aria-label=${t('手机号')}
                value=${phone}
                onInput=${(e) => changePhone(e.currentTarget.value)}
              />`,
            )}
            ${field(
              '验证码',
              html`<div class="si-code">
                <input
                  ref=${fields.code}
                  class="field si-input"
                  autocomplete="one-time-code"
                  inputmode="numeric"
                  aria-label=${t('验证码')}
                  value=${code}
                  onInput=${(e) => setCode(e.currentTarget.value)}
                />
                <button
                  class="btn"
                  disabled=${isBusy || remaining > 0 || !isValidPhoneNumber(normalizedPhone)}
                  onClick=${sendCode}
                >
                  ${sending ? t('正在发送…') : remaining > 0 ? tf('%d 秒后重发', remaining) : t('获取验证码')}
                </button>
              </div>`,
            )}`
          : html`${field(
              '邮箱',
              html`<input
                ref=${fields.email}
                class="field si-input"
                type="email"
                autocomplete="username"
                placeholder="name@example.com"
                aria-label=${t('邮箱')}
                aria-description=${emailHint}
                value=${email}
                onInput=${(e) => setEmail(e.currentTarget.value)}
              />`,
            )}
            ${field(
              '密码',
              html`<input
                ref=${fields.password}
                class="field si-input"
                type="password"
                autocomplete="current-password"
                aria-label=${t('密码')}
                aria-description=${passwordHint}
                value=${password}
                onInput=${(e) => setPassword(e.currentTarget.value)}
              />`,
            )}
            ${note('国家或地区选错会登录失败。', 'info.circle')} ${note('密码不会保存。', 'lock')}`}
        ${attempted && validation
          ? html`<div class="si-message si-message--warn" role="status">
              <${Icon} name="exclamationmark.circle.fill" class="si-message__icon c-warn" />
              <span class="t-caption c-warn">${validation}</span>
            </div>`
          : null}
        ${error
          ? html`<div class="si-message si-message--error" role="alert">
              <${Icon} name="exclamationmark.triangle.fill" class="si-message__icon c-danger" />
              <span class="t-caption c-danger para">${tt(error)}</span>
            </div>`
          : null}
      </div>

      <div class="dv-hline"></div>

      <div class="si-footer">
        ${engineSigningIn || submitting
          ? html`<${Spinner} /><span class="t-caption c-tertiary">${t('正在登录…')}</span>`
          : null}
        <span class="dv-spacer"></span>
        <button class="btn" onClick=${cancel}>${t('取消')}</button>
        <button
          class=${cx('btn', 'is-primary')}
          disabled=${isBusy}
          aria-description=${validation ?? t('登录 Anker 账号')}
          onClick=${primaryAction}
        >
          ${primaryTitle}
        </button>
      </div>
    </div>
  </div>`;
}
