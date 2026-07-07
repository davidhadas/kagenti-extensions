export interface Agent {
  name: string;
  namespace: string;
  description: string;
  status: string;
  labels: {
    protocol?: string[];
    framework?: string;
    type?: string;
  };
  workloadType: string;
  createdAt: string;
  tags?: string[];
  examples?: string[];
  security?: boolean;
}

export interface AuthConfig {
  enabled: boolean;
  token_broker_enabled?: boolean;
}

export interface TokenBrokerEvent {
  type: string;
  auth_url?: string;
  message?: string;
  code?: string;
}

export interface User {
  username: string;
  email?: string;
  firstName?: string;
  lastName?: string;
}
