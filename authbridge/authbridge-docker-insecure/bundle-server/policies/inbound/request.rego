# Inbound request policy — authbridge-compose starter
#
# Inbound pipeline is empty (no jwt-validation) so OPA is not in the
# inbound pipeline by default. This file is a placeholder for when you
# add inbound JWT validation later.
#
# Uncomment and add to the inbound pipeline config when ready:
#
#   default allow := false
#   allow if { input.identity.subject != "" }
package authbridge.inbound.request

default allow := true
