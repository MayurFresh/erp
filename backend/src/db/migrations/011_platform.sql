-- v1.7 platform: SSO issuers may be plain http on the loopback address (local IdPs and tests); the API enforces https elsewhere.
alter table sso_providers drop constraint sso_providers_issuer_check;
alter table sso_providers add constraint sso_providers_issuer_check check (issuer ~ '^https?://');
