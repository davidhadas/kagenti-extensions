/**
 * CallbackPage — handles the simulated IdP redirect.
 *
 * Reads ?code=X from URL, exchanges it for a JWT via GET /api/v1/auth/token,
 * stores the token in sessionStorage, then redirects to /agents.
 * Same role as Keycloak's redirect_uri handler in the original app-demo.
 */
import React, { useEffect } from 'react';
import { Spinner } from '@patternfly/react-core';

const API_BASE = '/api/v1';
const TOKEN_KEY = 'rossocortex_access_token';

export const CallbackPage: React.FC = () => {
  useEffect(() => {
    const code = new URLSearchParams(window.location.search).get('code');
    if (!code) {
      window.location.replace('/');
      return;
    }

    fetch(`${API_BASE}/auth/token?code=${encodeURIComponent(code)}`)
      .then(r => r.json())
      .then(({ access_token }) => {
        if (access_token) {
          sessionStorage.setItem(TOKEN_KEY, access_token);
        }
        // FULL-PAGE navigation to /agents (not client-side) so AuthProvider
        // remounts and its init() runs fresh: it finds this token and creates
        // exactly ONE broker session with this token's jti. A client-side
        // navigate would leave AuthProvider mounted with init() already done,
        // so no session would be created for this token.
        window.location.replace('/agents');
      })
      .catch(() => window.location.replace('/'));
  }, []);

  return (
    <div style={{ display: 'flex', justifyContent: 'center', alignItems: 'center', height: '60vh' }}>
      <Spinner size="xl" />
    </div>
  );
};
