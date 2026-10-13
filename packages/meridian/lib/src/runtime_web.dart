/// A project key must stay out of a browser.
const String serverRuntimeRefusal =
    'The server client holds a project key and must not run in a browser. Use MeridianBrowser from package:meridian_flutter, which calls your own backend.';

/// Provisioning must run on a server.
const String adminRuntimeRefusal =
    'The admin client holds an integrator key. Provisioning belongs on a server, never in a browser.';
