package cloudsession

import (
	"charker/internal/anker"
	"charker/internal/session"
)

// Phase is the A2345 connection phase (A2345ConnectionPhase).
type Phase string

// Connection phases.
const (
	PhaseIdle                Phase = "idle"
	PhaseSigningIn           Phase = "signingIn"
	PhaseLoadingDevices      Phase = "loadingDevices"
	PhaseConnecting          Phase = "connecting"
	PhaseWaitingForTelemetry Phase = "waitingForTelemetry"
	PhaseMonitoring          Phase = "monitoring"
	PhaseReconnecting        Phase = "reconnecting"
	PhaseFailed              Phase = "failed"
)

// IsLive: subscribed and either waiting for or receiving telemetry.
func (p Phase) IsLive() bool { return p == PhaseWaitingForTelemetry || p == PhaseMonitoring }

// IsBusy: an operation is in flight that the user should not restart.
func (p Phase) IsBusy() bool {
	switch p {
	case PhaseSigningIn, PhaseLoadingDevices, PhaseConnecting, PhaseReconnecting:
		return true
	}
	return false
}

// SessionPhase maps onto the A2687 engine's vocabulary so product-neutral
// pages can read one field: monitoring is polling, the in-between phases are
// connecting, and the precise A2345 phase stays in Snapshot.Stage.
func (p Phase) SessionPhase() session.Phase {
	switch p {
	case PhaseMonitoring:
		return session.PhasePolling
	case PhaseSigningIn, PhaseLoadingDevices, PhaseConnecting, PhaseWaitingForTelemetry:
		return session.PhaseConnecting
	case PhaseReconnecting:
		return session.PhaseReconnecting
	case PhaseFailed:
		return session.PhaseFailed
	}
	return session.PhaseIdle
}

// ShortLabel is A2345ConnectionPhase.shortLabel.
func (p Phase) ShortLabel() anker.Text {
	switch p {
	case PhaseSigningIn:
		return anker.T("登录中")
	case PhaseLoadingDevices:
		return anker.T("查找设备")
	case PhaseConnecting:
		return anker.T("连接云端")
	case PhaseWaitingForTelemetry:
		return anker.T("等待数据")
	case PhaseMonitoring:
		return anker.T("已连接")
	case PhaseReconnecting:
		return anker.T("重连中")
	case PhaseFailed:
		return anker.T("出错")
	}
	return anker.T("未连接")
}

// detail is A2345ConnectionPhase.detail; failure is the failed reason.
func (p Phase) detail(attempt int, failure anker.Text) anker.Text {
	switch p {
	case PhaseSigningIn:
		return anker.T("正在验证 Anker 账号")
	case PhaseLoadingDevices:
		return anker.T("正在读取账号下绑定的充电器")
	case PhaseConnecting:
		return anker.T("正在建立加密 MQTT 订阅")
	case PhaseWaitingForTelemetry:
		return anker.T("订阅已建立，正在等待充电器上报")
	case PhaseMonitoring:
		return anker.T("正在接收 Wi-Fi 实时数据")
	case PhaseReconnecting:
		return anker.T("云端连接中断，正在第 %d 次重试", attempt)
	case PhaseFailed:
		return failure
	}
	return anker.T("使用 Anker 账号连接 A2345")
}

// ReconnectBudget is the retry budget of one cloud generation
// (A2345ReconnectBudget).
//
// A valid realtime frame proves the subscription recovered, so a later
// disconnect starts a new consecutive-failure streak instead of consuming a
// process-lifetime counter. Merely connecting or subscribing does not reset
// the budget because a telemetry-starved socket is not healthy yet.
type ReconnectBudget struct {
	MaximumConsecutiveFailures int
	ConsecutiveFailures        int
}

// NewReconnectBudget allows maximum (at least 1) consecutive failures.
func NewReconnectBudget(maximum int) ReconnectBudget {
	return ReconnectBudget{MaximumConsecutiveFailures: max(1, maximum)}
}

// RecordValidTelemetry resets the streak.
func (b *ReconnectBudget) RecordValidTelemetry() { b.ConsecutiveFailures = 0 }

// RecordFailure counts one failed subscription and reports whether another
// attempt is still allowed.
func (b *ReconnectBudget) RecordFailure() bool {
	b.ConsecutiveFailures++
	return b.ConsecutiveFailures < b.MaximumConsecutiveFailures
}

// RetryDelaySeconds is exponential and capped at 16 s; the shift is capped
// too so custom budgets cannot overflow.
func (b ReconnectBudget) RetryDelaySeconds() int {
	return 1 << min(max(0, b.ConsecutiveFailures-1), 4)
}
