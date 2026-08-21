# Provider-specific integrations

Create a provider subdirectory only after the wallet or portfolio service publishes concrete integration requirements.

Provider code must remain a thin wrapper around `../core/reference-adapter.js`. Do not duplicate registry discovery,
vault reads or pro-rata NAV calculation. Keeping one accounting core prevents MetaMask, Rabby, DeBank, Zerion or future
integrations from drifting to different Liquid Hub position values.

Never include API keys, private RPC URLs, deployment credentials or unpublished addresses in a provider package.
