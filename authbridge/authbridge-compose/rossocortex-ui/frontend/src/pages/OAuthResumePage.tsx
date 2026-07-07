/**
 * OAuthResumePage — landing point after the full-page OAuth redirect.
 *
 * The token-broker redirects the whole browser here once OAuth completes.
 * It determines which chat to return to using, in priority order:
 *   1. URL query params ?ns=..&name=..  (defense-in-depth — survives even if
 *      sessionStorage was cleared during a cross-origin context switch;
 *      the token-broker preserves existing query params on the redirect URL)
 *   2. The pending task saved in sessionStorage (the primary same-origin path)
 *   3. Fallback to /agents
 */
import React, { useEffect } from 'react';
import { Spinner } from '@patternfly/react-core';
import { useNavigate } from 'react-router-dom';

const PENDING_KEY = 'rossocortex_pending_task';

export const OAuthResumePage: React.FC = () => {
  const navigate = useNavigate();

  useEffect(() => {
    const params = new URLSearchParams(window.location.search);
    let ns = params.get('ns') || '';
    let name = params.get('name') || '';

    // Fall back to the pending task in sessionStorage.
    if (!ns || !name) {
      const raw = sessionStorage.getItem(PENDING_KEY);
      if (raw) {
        try {
          const p = JSON.parse(raw);
          ns = ns || p.namespace;
          name = name || p.name;
        } catch {
          /* ignore */
        }
      }
    }

    if (ns && name) {
      navigate(`/chat/${encodeURIComponent(ns)}/${encodeURIComponent(name)}`, { replace: true });
    } else {
      navigate('/agents', { replace: true });
    }
  }, [navigate]);

  return (
    <div style={{ display: 'flex', justifyContent: 'center', alignItems: 'center', height: '60vh' }}>
      <Spinner size="xl" />
    </div>
  );
};
