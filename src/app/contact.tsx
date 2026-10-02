import {useState,useEffect} from 'react';
import {MessageCircle,Mail,Copy,ExternalLink} from 'lucide-react';
import {registerInterest,openConversation} from './inbox';
import {supabase} from '../lib/supabase';
export default function ContactButtons({profile,item}:{profile:any,item?:any}){
 const [status,setStatus]=useState(''),[text,setText]=useState(''),[busy,setBusy]=useState(false),[self,setSelf]=useState(false);
 useEffect(()=>{supabase.auth.getSession().then(({data})=>setSelf(!!item&&data.session?.user.id===item.owner))},[item?.id]);
 const link=()=>location.origin+(item?'/account/'+encodeURIComponent(item.id):'/profile');
 const message=()=>item?`Hi! I am interested in ${item.title} on Valorant Buy & Sell (${new Intl.NumberFormat('en-PH',{style:'currency',currency:'PHP',maximumFractionDigits:0}).format(+item.price)}). Is it still available?\n\n${link()}`:'Hi! I found your seller profile on Valorant Buy & Sell. I would like to inquire about your listings.';
 async function contact(channel:string,url?:string){
 if(busy)return;setBusy(true);setStatus('');
 // Open synchronously so the browser does not block the external contact window.
 const popup=url&&channel!=='email'?window.open('about:blank','_blank'):null;if(popup)popup.opener=null;
 try{
 let result:any;if(item&&!self)result=await registerInterest(item,channel);
 if(channel==='website'){openConversation(result.threadId);setStatus('Interest recorded. You can chat with the seller in your inbox.');}
 else if(channel==='copy'){setText(message());try{await navigator.clipboard.writeText(message());setStatus(item?'Interest recorded. Message copied; paste it into your conversation.':'Message copied.')}catch{setStatus('Select and copy the message below.')}}
 else {if(popup&&url)popup.location.href=url;else if(url)location.assign(url);setStatus(item?'Interest recorded. Send the prepared message in your chosen channel.':'Contact channel opened.');}
 }catch(e:any){popup?.close();setStatus(e.message)}finally{setBusy(false)}
 }
 if(self)return <p className="form-help">This is your listing. Interested buyers and their messages will appear in your Inbox.</p>;
 return <div className="contact-channels"><h3>{item?'Interested in this account?':'Contact '+(profile?.name||'seller')}</h3>{item&&<button className="primary full" disabled={busy} onClick={()=>contact('website')}><MessageCircle size={18}/>{busy?'Connecting…':'Mine / Buy · Chat with seller'}</button>}<p>{item?'Choose a channel to record your interest and notify the seller.':'Choose a contact channel.'}</p><div className="channel-buttons">{profile?.whatsapp&&<button disabled={busy} className="channel whatsapp" onClick={()=>contact('whatsapp','https://wa.me/'+profile.whatsapp+'?text='+encodeURIComponent(message()))}><MessageCircle size={17}/>WhatsApp</button>}{profile?.email&&<button disabled={busy} className="channel" onClick={()=>contact('email','mailto:'+encodeURIComponent(profile.email)+'?subject='+encodeURIComponent(item?'Interested: '+item.title:'Valorant inquiry')+'&body='+encodeURIComponent(message()))}><Mail size={17}/>Email</button>}{profile?.facebook&&<button disabled={busy} className="channel facebook" onClick={()=>contact('facebook',profile.facebook)}><ExternalLink size={17}/>Facebook</button>}<button disabled={busy} className="channel" onClick={()=>contact('copy')}><Copy size={16}/>Copy message</button></div>{status&&<p role="status" className="copy-status">{status}</p>}{text&&<textarea className="copy-message" readOnly value={text} aria-label="Generated inquiry message"/>}<small>{item?'Mine/Buy records interest; it does not reserve the account or complete a purchase. ':''}You choose when to send external messages. For Facebook, use Copy message and paste it into your conversation.</small></div>
}
