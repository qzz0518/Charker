//go:build !windows

package app

import "errors"

// Only Windows puts a firewall prompt between the helper and the network
// (macOS asks for local network access itself).

const firewallGatesHome = false

func homeFirewall(string) string { return "allowed" }

var errFirewallDeclined = errors.New("firewall: the administrator prompt was declined")

func allowHomeFirewall(string) error { return nil }
