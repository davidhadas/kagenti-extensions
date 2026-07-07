# broker-routes-assemble — one-shot that assembles the single broker-routes.yaml
# every authbridge sidecar reads, from the per-tool *.frag.yaml fragments each
# tool registrar drops into the broker_routes volume.
#
# Phase 30: runs AFTER all tool route registrars (phase 20) and BEFORE the
# authbridge sidecars (phase 40, which declare --needs-completed on this).
# Seeds an EMPTY file first so the file always exists (authbridge errors on a
# set-but-missing routes file), then appends every fragment. Fragment discovery
# is a runtime glob, so a newly added OAuth tool's fragment is picked up with no
# edit here.
unit_name broker-routes-assemble
phase 30

oneshot --name broker-routes-assemble --image busybox \
  --volume broker_routes:/routes \
  --cmd -- sh -c ': > /routes/broker-routes.yaml
for f in /routes/*.frag.yaml; do
  [ -f "$f" ] && cat "$f" >> /routes/broker-routes.yaml
done
echo "assembled broker-routes.yaml:"; cat /routes/broker-routes.yaml'
