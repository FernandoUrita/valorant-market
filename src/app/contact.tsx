'use client';
import {useState,useEffect} from 'react';
import {MessageCircle,Mail,Copy,ExternalLink} from 'lucide-react';
export default function ContactButtons({profile,item}:{profile:any,item?:any}){
 const [status,setStatus]=useState('');
 const [origin,setOrigin]=useState('');useEffect(()=>setOrigin(window.location.origin),[]);
 const link=()=>origin+(item?'/account/'+encodeURIComponent(item.id):'/profile');
 const message=()=>item?`Hi! I saw your ${item.title} listing on Valorant Buy & Sell (${new Intl.NumberFormat('en-PH',{style:'currency',currency:'PHP',maximumFractionDigits:0}).format(+item.price)}). Is it still available?\n\n${link()}`:'Hi! I found your seller profile on Valorant Buy & Sell. I would like to inquire about your listings.';
 const [text,setText]=useState('');
 async function copy(){const m=message();setText(m);try{await navigator.clipboard.writeText(m);setStatus('Message copied. Paste it into your Facebook conversation.')}catch{setStatus('Select and copy the message below.')}}
 if(!profile?.email&&!profile?.whatsapp&&!profile?.facebook)return <p className="form-help">Seller has not added contact channels yet.</p>;
 return <div className="contact-channels"><h3>Contact {profile.name||'seller'}</h3><p>Choose a channel. Your inquiry includes this listing’s link.</p><div className="channel-buttons">{profile.whatsapp&&<a className="channel whatsapp" href={'https://wa.me/'+profile.whatsapp+'?text='+encodeURIComponent(message())} target="_blank" rel="noreferrer"><MessageCircle size={17}/>WhatsApp</a>}{profile.email&&<a className="channel" href={'mailto:'+encodeURIComponent(profile.email)+'?subject='+encodeURIComponent(item?'Inquiry: '+item.title:'Valorant Buy & Sell inquiry')+'&body='+encodeURIComponent(message())}><Mail size={17}/>Email</a>}{profile.facebook&&<a className="channel facebook" href={profile.facebook} target="_blank" rel="noreferrer"><ExternalLink size={17}/>Facebook</a>}<button className="channel" type="button" onClick={copy}><Copy size={16}/>Copy message</button></div>{status&&<p role="status" className="copy-status">{status}</p>}{text&&<textarea className="copy-message" readOnly value={text} aria-label="Generated inquiry message"/>}<small>Messages are prepared for you; you choose when to send them. For Facebook, copy the message and paste it after opening the seller’s profile.</small></div>
}
