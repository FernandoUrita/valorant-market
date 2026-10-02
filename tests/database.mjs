import {PGlite} from '@electric-sql/pglite';
import fs from 'node:fs';
import assert from 'node:assert/strict';
const db=new PGlite();
await db.exec("create role anon;create role authenticated;create schema auth;create table auth.users(id uuid primary key,email text,email_confirmed_at timestamptz,raw_user_meta_data jsonb default '{}');create function auth.uid() returns uuid language sql as $$select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid$$;");
await db.exec(fs.readFileSync('supabase/setup.sql','utf8'));
const ids={admin:'00000000-0000-4000-8000-000000000001',seller:'00000000-0000-4000-8000-000000000002',buyer:'00000000-0000-4000-8000-000000000003',stranger:'00000000-0000-4000-8000-000000000004',midman:'00000000-0000-4000-8000-000000000005'};
for(const [name,id] of Object.entries(ids)){await db.query('insert into auth.users(id,email,email_confirmed_at) values($1,$2,now())',[id,name==='admin'?'uritaf40@gmail.com':name+'@example.com'])}
async function as(name){await db.query("select set_config('request.jwt.claim.sub',$1,false)",[ids[name]||''])}
async function read(scope='market'){return (await db.query('select public.vm_read($1) as d',[scope])).rows[0].d}
async function write(action,payload){return (await db.query('select public.vm_write($1,$2::jsonb) as d',[action,JSON.stringify(payload)])).rows[0].d}
await as('seller');assert.equal((await read()).user.role,'buyer');assert.equal((await read()).user.credits,100);
await write('request-role',{role:'seller',details:'I have experience selling accounts.'});let rr=(await read('trust')).requests[0];await assert.rejects(()=>write('review-role',{id:rr.id,decision:'approved'}));
await as('admin');await read();await write('review-role',{id:rr.id,decision:'approved'});
await as('midman');await read();await write('request-role',{role:'midman',details:'I can coordinate transactions.'});rr=(await read('trust')).requests[0];await as('admin');await write('review-role',{id:rr.id,decision:'approved'});
await as('buyer');await read();await as('stranger');await read();await as('seller');
await write('save-record',{kind:'profile',data:{name:'Seller',bio:'Hello',email:'seller@example.com',facebook:'https://facebook.com/seller',whatsapp:'09171234567',role:'midman',credits:1000}});assert.equal((await read()).user.role,'seller');
const catalog=JSON.parse(fs.readFileSync('src/lib/catalog.json','utf8'));const inv=Object.fromEntries(Object.entries(catalog).map(([k,v])=>[k,[v[0].id]]));
const listing={title:'Test account',price:'3500',rank:'Gold',region:'APAC',level:'50',description:'Collection details',image:catalog.weapons[0].image,urgency:'rush',inventory:inv};
const lid=(await write('save-record',{kind:'listing',data:listing})).id;assert.deepEqual((await read()).records.find(r=>r.id===lid).inventory,inv);
await write('create-deal',{listingId:lid,buyer:ids.buyer});let deal=(await read('trust')).deals[0];
await as('stranger');await assert.rejects(()=>write('confirm-deal',{id:deal.id}));
await as('buyer');await write('confirm-deal',{id:deal.id});await as('seller');assert.equal((await read('trust')).members.find(m=>m.id===ids.seller).sales,1);assert.equal((await read()).records.find(r=>r.id===lid).sold,true);
for(let i=0;i<4;i++){
 await as('seller');const newlid=(await write('save-record',{kind:'listing',data:listing})).id;
 await as('buyer');await write('report',{listingId:newlid,reason:'Reported transaction issue',evidence:'Evidence details with links'});const rep=(await read('trust')).reports.find(r=>r.listing===newlid);
 await as('stranger');await assert.rejects(()=>write('review-report',{id:rep.id,decision:'confirmed'}));
 await as('admin');await write('review-report',{id:rep.id,decision:'confirmed'});await assert.rejects(()=>write('review-report',{id:rep.id,decision:'confirmed'}));
}
await as('seller');assert.equal((await read()).user.suspended,true);await assert.rejects(()=>write('request-role',{role:'midman',details:'Request while suspended'}));
await db.query("update vm.members set suspended_until=now()-interval '1 second' where id=$1",[ids.seller]);assert.equal((await read()).user.credits,25);assert.equal((await read()).user.suspended,undefined);
await as('buyer');await write('save-record',{kind:'inquiry',data:{listingId:lid,sellerId:ids.stranger,message:'Hello seller'}});const inquiries=(await read()).records.filter(r=>r.kind==='inquiry');assert.equal(inquiries[0].sellerId,ids.seller);
await as('stranger');assert.equal((await read()).records.filter(r=>r.kind==='inquiry').length,0);
await as('');assert.equal((await read()).user,null);
await db.exec('set role anon');await assert.rejects(()=>db.query('select * from vm.members'));await assert.rejects(()=>write('request-role',{role:'seller',details:'Untrusted request'}));await read();await db.exec('reset role');
console.log('PASS: schema, inventory, roles, admin authorization, transaction confirmation, null-midman ownership, credits, report idempotency, suspension/recovery, private inquiries, anonymous access restrictions.');await db.close();
