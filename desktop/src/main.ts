import { startApp } from './app';
import { connection } from './core/connection';

startApp(document.getElementById('app')!, connection);
