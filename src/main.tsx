import {useEffect,useState} from 'react';
import {createRoot} from 'react-dom/client';
import Market from './app/market';
import {supabase} from './lib/supabase';
import './app/globals.css';
function App(){const [ready,setReady]=useState(false),[error,setError]=useState(''),[version,setVersion]=useState(0);const path=location.pathname;
useEffect(()=>{supabase.auth.getSession().then(({error})=>{if(error)setError(error.message);setReady(true)}).catch(e=>{setError(e.message);setReady(true)});const {data}=supabase.auth.onAuthStateChange(()=>setVersion(v=>v+1));return()=>data.subscription.unsubscribe()},[]);
useEffect(()=>{if(!ready)return;async function run(){if(path==='/login'){const {error}=await supabase.auth.signInWithOAuth({provider:'google',options:{redirectTo:location.origin+'/auth/callback'}});if(error)setError(error.message)}if(path==='/logout'){const {error}=await supabase.auth.signOut();if(error)setError(error.message);else location.replace('/')}}run()},[ready]);
if(!ready)return <div className="empty">Loading session…</div>;
if(path==='/login'||path==='/logout')return <main className="empty"><h2>{error?'Sign-in unavailable':'Connecting…'}</h2><p>{error||'Opening your Google account sign-in.'}</p>{error&&<><p>Google sign-in must be enabled in this project’s Supabase Authentication settings.</p><a className="primary" href="/">Back to marketplace</a></>}</main>;
if(path==='/auth/callback'){if(error||new URLSearchParams(location.search).has('error'))return <main className="empty"><h2>Sign-in could not be completed</h2><p>{error||new URLSearchParams(location.search).get('error_description')}</p><a href="/login" className="primary">Try again</a></main>;location.replace('/profile');return <div className="empty">Completing sign-in…</div>}
const match=path.match(/^\/account\/([^/]+)$/);return <Market key={version} initial={match?'account':path.slice(1)||'market'} accountId={match?decodeURIComponent(match[1]):undefined}/>}
createRoot(document.getElementById('root')!).render(<App/>);
