import React from 'react';
import { createRoot, hydrateRoot } from 'react-dom/client';
import App from './App.jsx';
import 'lenis/dist/lenis.css';
import '../styles.css';
const element = document.getElementById('root');
const app = <React.StrictMode><App /></React.StrictMode>;
if (element.querySelector('main')) hydrateRoot(element, app);
else createRoot(element).render(app);
