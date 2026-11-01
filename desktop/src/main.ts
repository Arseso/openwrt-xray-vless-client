import { startApp } from './app';
import { connection } from './core/connection';
import { startTray } from './tray';
import { liveHistory } from './core/history';
import { startNotifications } from './core/notify';

startNotifications(connection);
liveHistory.attach(connection);
startApp(document.getElementById('app')!, connection);
startTray(connection);
