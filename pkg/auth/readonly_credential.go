package auth

import (
	"strings"

	"github.com/treeverse/lakefs/pkg/permissions"
)

// ActionPermittedForReadOnlyCredential reports whether a read-only access key may perform the action.
func ActionPermittedForReadOnlyCredential(action string) bool {
	if action == "" || action == permissions.All {
		return false
	}
	switch {
	case strings.HasPrefix(action, "fs:Read"),
		strings.HasPrefix(action, "fs:List"),
		strings.HasPrefix(action, "auth:Read"),
		strings.HasPrefix(action, "auth:List"),
		action == permissions.ReadActionsAction, // ci:ReadAction
		strings.HasPrefix(action, "retention:Get"),
		strings.HasPrefix(action, "branches:Get"),
		strings.HasPrefix(action, "pr:Read"),
		strings.HasPrefix(action, "pr:List"),
		strings.HasPrefix(action, "catalog:List"),
		strings.HasPrefix(action, "catalog:Get"),
		strings.HasPrefix(action, "catalog:Read"):
		return true
	default:
		return false
	}
}

func collectPermActions(n permissions.Node) []string {
	switch n.Type {
	case permissions.NodeTypeNode:
		if n.Permission.Action != "" {
			return []string{n.Permission.Action}
		}
	case permissions.NodeTypeOr, permissions.NodeTypeAnd:
		var out []string
		for _, child := range n.Nodes {
			out = append(out, collectPermActions(child)...)
		}
		return out
	}
	return nil
}
