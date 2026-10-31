// The connection to one router profile: login, package check, the shared poller. One
// instance for the app (connection below); its bus lives across profiles, so the tray
// and notifications subscribe once at startup.
//
// Phases (ConnectionState.phase, the 'connection' event on each change):
//   disconnected  no profile chosen
//   connecting    logging in and checking the package
//   online        the poller runs, AppContext is ready for the tabs
//   offline       the router does not answer (rebooting, off): retried by itself; with a
//                 context (was online) the poller keeps going and brings it back
//   failed        an error the user has to act on (password, certificate, package);
//                 no retries, the connect screen shows error

import { XvpnError, toXvpnError } from '../api/errors';
import { Profile } from '../api/profiles';
import { TauriTransport, Transport } from '../api/transport';
import { UbusClient } from '../api/ubus';
import { UciApi } from '../api/uci';
import { PackageInfo, checkPackage } from '../api/version';
import { XvpnApi } from '../api/xvpn';
import { Bus } from './bus';
import { PollerEvents, StatusPoller } from './poller';
import { Store } from './store';

export type Phase = 'disconnected' | 'connecting' | 'online' | 'offline' | 'failed';

export interface ConnectionState {
  phase: Phase;
  profile: Profile | null;
  /** luci-app-xvpn on the router, after a successful check */
  pkg: PackageInfo | null;
  error: XvpnError | null;
}

export interface AppEvents extends PollerEvents {
  connection: ConnectionState;
}

/** what a tab gets on mount: valid until the profile changes (the tab is remounted) */
export interface AppContext {
  profile: Profile;
  pkg: PackageInfo;
  ubus: UbusClient;
  xvpn: XvpnApi;
  uci: UciApi;
  poller: StatusPoller;
  bus: Bus<AppEvents>;
}

export interface ConnectionOptions {
  intervalMs?: number;
  /** pause between attempts while the router does not answer */
  retryMs?: number;
  transport?: (profile: Profile) => Transport;
}

export class Connection {
  readonly bus = new Bus<AppEvents>();
  readonly state = new Store<ConnectionState>({ phase: 'disconnected', profile: null, pkg: null, error: null });
  private ctx: AppContext | null = null;
  private gen = 0;
  private offs: (() => void)[] = [];
  private retry: ReturnType<typeof setTimeout> | null = null;

  constructor(private readonly opts: ConnectionOptions = {}) {
    this.state.subscribe((s) => this.bus.emit('connection', s));
  }

  get context(): AppContext | null {
    return this.ctx;
  }

  /** resolves once online, failed or disconnected; offline keeps retrying behind it */
  connect(profile: Profile): Promise<ConnectionState> {
    this.disconnect();
    const gen = ++this.gen;
    const transport = (this.opts.transport ?? ((p) => new TauriTransport(p.id)))(profile);
    const ubus = new UbusClient(transport);
    const xvpn = new XvpnApi(ubus);
    this.state.set({ phase: 'connecting', profile, pkg: null, error: null });
    return new Promise((resolve) => {
      const attempt = async () => {
        this.retry = null;
        try {
          await ubus.login();
          const pkg = await checkPackage(xvpn);
          if (gen !== this.gen)
            return resolve(this.state.get());
          this.online(profile, pkg, ubus, xvpn);
        }
        catch (e) {
          if (gen !== this.gen)
            return resolve(this.state.get());
          const error = toXvpnError(e);
          if (error.offline) {
            this.state.set({ phase: 'offline', error });
            this.retry = setTimeout(attempt, this.opts.retryMs ?? 5000);
            return;
          }
          this.state.set({ phase: 'failed', error });
        }
        resolve(this.state.get());
      };
      void attempt();
    });
  }

  disconnect(): void {
    this.gen++;
    if (this.retry)
      clearTimeout(this.retry);
    this.retry = null;
    this.ctx?.poller.stop();
    this.ctx = null;
    for (const off of this.offs.splice(0))
      off();
    if (this.state.get().phase !== 'disconnected')
      this.state.set({ phase: 'disconnected', profile: null, pkg: null, error: null });
  }

  private online(profile: Profile, pkg: PackageInfo, ubus: UbusClient, xvpn: XvpnApi): void {
    const poller = new StatusPoller(xvpn, this.bus, { intervalMs: this.opts.intervalMs });
    this.ctx = { profile, pkg, ubus, xvpn, uci: new UciApi(ubus), poller, bus: this.bus };
    const gen = this.gen;
    this.offs.push(
      this.bus.on('router-down', ({ error }) => this.state.set({ phase: 'offline', error })),
      // the package may have been upgraded while the router was away
      this.bus.on('router-up', () => {
        checkPackage(xvpn).then((p) => {
          if (gen !== this.gen)
            return;
          if (this.ctx)
            this.ctx.pkg = p;
          this.state.set({ phase: 'online', pkg: p, error: null });
        }, (e) => {
          if (gen !== this.gen)
            return;
          const error = toXvpnError(e);
          if (!error.offline) {
            poller.stop();
            this.ctx = null;
            this.state.set({ phase: 'failed', error });
          }
        });
      }),
    );
    this.state.set({ phase: 'online', pkg, error: null });
    poller.start();
  }
}

export const connection = new Connection();
