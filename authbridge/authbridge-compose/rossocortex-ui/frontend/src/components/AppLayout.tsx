import React from 'react';
import {
  Button, Masthead, MastheadBrand, MastheadContent, MastheadMain,
  Page, PageSection, Toolbar, ToolbarContent, ToolbarGroup, ToolbarItem,
} from '@patternfly/react-core';
import { UserIcon } from '@patternfly/react-icons';
import { Outlet, useNavigate } from 'react-router-dom';

import { useAuth } from '@/contexts/AuthContext';

export const AppLayout: React.FC = () => {
  const { isAuthenticated, user, login, tokenBrokerEnabled, sessionHealthy } = useAuth();
  const navigate = useNavigate();

  // Token-broker connectivity indicator. Hidden entirely when no broker is
  // configured (system runs without HITL). Green = connected, amber = down.
  const brokerIndicator = tokenBrokerEnabled ? (
    <span
      title={sessionHealthy ? 'Authorization service connected' : 'Authorization service unavailable'}
      style={{ display: 'flex', alignItems: 'center', gap: '6px', color: '#c9c9c9', fontSize: '13px' }}
    >
      <span
        style={{
          width: '10px', height: '10px', borderRadius: '50%', flexShrink: 0,
          background: sessionHealthy ? '#3e8635' : '#f0ab00',
          boxShadow: sessionHealthy ? '0 0 6px #3e8635' : '0 0 6px #f0ab00',
        }}
      />
      {sessionHealthy ? 'Auth connected' : 'Auth reconnecting…'}
    </span>
  ) : null;

  const mastheadEl = (
    <Masthead>
      <MastheadMain>
        <MastheadBrand>
          <span style={{ display: 'flex', alignItems: 'center', gap: '8px', color: '#fff', fontSize: '18px', fontWeight: 700, letterSpacing: '0.5px' }}>
            <span style={{ background: '#8b0000', borderRadius: '50%', width: '32px', height: '32px', display: 'flex', alignItems: 'center', justifyContent: 'center', fontWeight: 800, fontSize: '18px', flexShrink: 0 }}>
              R
            </span>
            RossoCortex
          </span>
        </MastheadBrand>
      </MastheadMain>
      <MastheadContent>
        <Toolbar isFullHeight>
          <ToolbarContent>
            <ToolbarGroup align={{ default: 'alignRight' }}>
              {brokerIndicator && <ToolbarItem>{brokerIndicator}</ToolbarItem>}
              {isAuthenticated && user ? (
                <>
                  <ToolbarItem>
                    <span style={{ color: '#fff', display: 'flex', alignItems: 'center', gap: '6px' }}>
                      <UserIcon />
                      {user.username}
                    </span>
                  </ToolbarItem>
                  <ToolbarItem>
                    <Button variant="plain" onClick={() => navigate('/agents')} style={{ color: '#73bcf7' }}>Agents</Button>
                  </ToolbarItem>
                </>
              ) : (
                <ToolbarItem>
                  <Button variant="plain" onClick={login} style={{ color: '#73bcf7' }}>Sign In</Button>
                </ToolbarItem>
              )}
            </ToolbarGroup>
          </ToolbarContent>
        </Toolbar>
      </MastheadContent>
    </Masthead>
  );

  return (
    <Page header={mastheadEl}>
      <PageSection isFilled>
        <Outlet />
      </PageSection>
    </Page>
  );
};
