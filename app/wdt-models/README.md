# WebLogic Deploy Tooling Model

This is the tiny WebLogic Deploy Tooling model used by this demo
auxiliary image. It creates a compact WebLogic domain and deploys
`demo-webapp.war` to `cluster-1` at `/demo`.

The auxiliary-image build expects the compiled WAR to be available inside the
WDT archive as:

```text
wlsdeploy/applications/demo-webapp.war
```

The resulting image intentionally does not contain a WebLogic installation.
`domain.spec.image` still points at a WebLogic+Java base image, while
`domain.spec.configuration.model.auxiliaryImages` points at this lightweight
demo artifact.

## Oracle Container Registry credentials

Never commit the OCR auth token. Keep it in a password manager and read it at run time
when creating the `ProjectSecret`; the platform docs in `docs/` show the pattern using
`read -rs` so the value never reaches a file or your shell history.
