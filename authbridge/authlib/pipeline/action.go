package pipeline

// ActionType represents the result of a plugin's processing.
type ActionType int

const (
	Continue ActionType = iota
	Reject
)

// Action is returned by a plugin to indicate whether processing should continue
// or the request should be rejected.
type Action struct {
	Type   ActionType
	Status int    // HTTP status code (only for Reject)
	Reason string // human-readable reason (only for Reject)
}
