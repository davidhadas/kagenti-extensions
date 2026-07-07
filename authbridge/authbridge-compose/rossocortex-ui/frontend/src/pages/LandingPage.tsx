import React, { useEffect, useRef, useState } from 'react';
import {
  Button,
  EmptyState,
  EmptyStateBody,
  EmptyStateHeader,
  EmptyStateIcon,
  Spinner,
} from '@patternfly/react-core';
import { RobotIcon } from '@patternfly/react-icons';
import { useNavigate } from 'react-router-dom';

import { useAuth } from '@/contexts/AuthContext';

export const LandingPage: React.FC = () => {
  const { isAuthenticated, isLoading, login } = useAuth();
  const navigate = useNavigate();

  // The demo mints a fake per-session token via login(); there is no real
  // sign-in step to show. So instead of presenting a Sign In button, we
  // auto-trigger login() once as soon as auth state has resolved and no token
  // is present — login() redirects through the callback and lands on /agents.
  const autoLoginTried = useRef(false);
  const [autoLoginFailed, setAutoLoginFailed] = useState(false);

  // If already authenticated (stored token found by init()), skip straight to agents.
  useEffect(() => {
    if (!isLoading && isAuthenticated) {
      navigate('/agents', { replace: true });
    }
  }, [isAuthenticated, isLoading, navigate]);

  // Auto-login once when unauthenticated. login() swallows its own errors, so
  // guard the (rare, BFF-unreachable) failure with a timeout: if we're still
  // here a few seconds later, fall back to the manual button.
  useEffect(() => {
    if (isLoading || isAuthenticated || autoLoginTried.current) return;
    autoLoginTried.current = true;
    login();
    const t = window.setTimeout(() => setAutoLoginFailed(true), 5000);
    return () => window.clearTimeout(t);
  }, [isLoading, isAuthenticated, login]);

  // While init() is resolving, or while the auto-login redirect is in flight,
  // show a spinner rather than flashing any landing content.
  if (isLoading || (!isAuthenticated && !autoLoginFailed)) {
    return (
      <div style={{ display: 'flex', justifyContent: 'center', alignItems: 'center', height: '60vh' }}>
        <Spinner size="xl" />
      </div>
    );
  }

  // Fallback only — reached if auto-login didn't redirect (e.g. BFF unreachable).
  return (
    <EmptyState>
      <EmptyStateHeader
        titleText="RossoCortex"
        icon={<EmptyStateIcon icon={RobotIcon} />}
        headingLevel="h1"
      />
      <EmptyStateBody>
        Interact with AI agents. Sign in to get started.
      </EmptyStateBody>
      <Button variant="primary" size="lg" onClick={login}>
        Sign In
      </Button>
    </EmptyState>
  );
};
