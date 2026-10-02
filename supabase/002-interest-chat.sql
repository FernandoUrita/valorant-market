-- Existing projects: run this migration after setup.sql. Keeps existing data.
begin;
create table if not exists vm.conversations (
 id uuid primary key default gen_random_uuid(), listing uuid not null references vm.records(id),
 buyer uuid not null references auth.users(id), seller uuid not null references auth.users(id),
 channel text not null default 'website', created timestamptz not null default now(),
 buyer_seen bigint not null default 0, seller_seen bigint not null default 0,
 unique(listing,buyer), check(buyer<>seller)
);
create table if not exists vm.messages (
 id bigint generated always as identity primary key,
 conversation uuid not null references vm.conversations(id) on delete cascade,
 sender uuid not null references auth.users(id), body text not null check(length(body) between 1 and 3000),
 created timestamptz not null default now()
);
create index if not exists vm_messages_thread on vm.messages(conversation,id);
alter table vm.conversations enable row level security;
alter table vm.messages enable row level security;
revoke all on vm.conversations,vm.messages from public,anon,authenticated;
revoke all on sequence vm.messages_id_seq from public,anon,authenticated;
create or replace function public.vm_chat(p_action text,p_data jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare m vm.members; other vm.members; r vm.records; c vm.conversations; msg_id bigint; new_thread boolean; contact_channel text; body text; cursor_id bigint;
begin
 m:=vm.ensure_member();
 if m.suspended_until>now() then raise exception 'Your account is temporarily suspended.' using errcode='42501';end if;
 if p_action='inbox' then
 return jsonb_build_object('threads',coalesce((select jsonb_agg(x.obj order by x.latest desc) from (
 select coalesce((select max(mm.id) from vm.messages mm where mm.conversation=cc.id),0) latest,
 to_jsonb(cc)||jsonb_build_object('title',rr.data->>'title','price',rr.data->>'price','sold',exists(select 1 from vm.deals d where d.listing=cc.listing and d.buyer_confirmed=1 and (d.midman is null or d.midman_confirmed=1)),
 'peerName',coalesce((select pr.data->>'name' from vm.records pr where pr.kind='profile' and pr.owner=case when cc.buyer=m.id then cc.seller else cc.buyer end order by pr.created desc limit 1),'Marketplace member'),
 'lastMessage',(select mm.body from vm.messages mm where mm.conversation=cc.id order by mm.id desc limit 1),
 'unread',(select count(*) from vm.messages mm where mm.conversation=cc.id and mm.sender<>m.id and mm.id>case when cc.buyer=m.id then cc.buyer_seen else cc.seller_seen end)) obj
 from vm.conversations cc join vm.records rr on rr.id=cc.listing where m.id in (cc.buyer,cc.seller)) x),'[]'::jsonb));
 elsif p_action='interest' then
 contact_channel:=coalesce(p_data->>'channel','website');
 if contact_channel not in ('website','whatsapp','facebook','email','copy') then raise exception 'Invalid contact channel.';end if;
 select * into r from vm.records where id=(p_data->>'listingId')::uuid and kind='listing';
 if r.id is null or r.owner=m.id then raise exception 'Choose an account from another seller.';end if;
 select * into other from vm.members where id=r.owner;
 if other.id is null or other.suspended_until>now() then raise exception 'Seller is unavailable.';end if;
 if exists(select 1 from vm.deals d where d.listing=r.id and d.buyer_confirmed=1 and (d.midman is null or d.midman_confirmed=1)) then raise exception 'This account has already been sold.';end if;
 insert into vm.conversations(listing,buyer,seller,channel) values(r.id,m.id,r.owner,contact_channel) on conflict do nothing returning * into c;
 new_thread:=c.id is not null;
 if not new_thread then select * into c from vm.conversations where listing=r.id and buyer=m.id for update;end if;
 if new_thread then
 insert into vm.messages(conversation,sender,body) values(c.id,m.id,'Hi! I am interested in '||left(r.data->>'title',250)||'. Is it still available? Contact preference: '||contact_channel||'.') returning id into msg_id;
 update vm.conversations set buyer_seen=msg_id where id=c.id;
 elsif c.channel<>contact_channel then update vm.conversations set channel=contact_channel where id=c.id;end if;
 return jsonb_build_object('threadId',c.id,'created',new_thread);
 else
 select * into c from vm.conversations where id=(p_data->>'threadId')::uuid for update;
 if c.id is null or m.id not in(c.buyer,c.seller) then raise exception 'Conversation unavailable.' using errcode='42501';end if;
 if p_action='messages' then
 cursor_id:=greatest(coalesce((p_data->>'before')::bigint,9223372036854775807),1);
 return jsonb_build_object('messages',coalesce((select jsonb_agg(to_jsonb(x) order by x.id) from (select mm.* from vm.messages mm where mm.conversation=c.id and mm.id<cursor_id order by mm.id desc limit 100) x),'[]'::jsonb));
 elsif p_action='seen' then
 -- Client supplies the last message actually displayed, avoiding unread races.
 select coalesce(max(id),0) into msg_id from vm.messages where conversation=c.id and id<=coalesce((p_data->>'lastId')::bigint,0);
 if m.id=c.buyer then update vm.conversations set buyer_seen=greatest(buyer_seen,msg_id) where id=c.id;
 else update vm.conversations set seller_seen=greatest(seller_seen,msg_id) where id=c.id;end if;
 return jsonb_build_object('ok',true);
 elsif p_action='send' then
 select * into other from vm.members where id=case when m.id=c.buyer then c.seller else c.buyer end;
 if other.suspended_until>now() then raise exception 'This member is temporarily unavailable.';end if;
 body:=trim(coalesce(p_data->>'body',''));
 if length(body) not between 1 and 3000 then raise exception 'Enter a message up to 3,000 characters.';end if;
 if exists(select 1 from vm.messages mm where mm.sender=m.id and mm.created>now()-interval '1 second') then raise exception 'Please wait a moment before sending another message.';end if;
 insert into vm.messages(conversation,sender,body) values(c.id,m.id,body) returning id into msg_id;
 return jsonb_build_object('ok',true,'id',msg_id);
 else raise exception 'Unknown chat action.';end if;
 end if;
end;$$;
revoke all on function public.vm_chat(text,jsonb) from public,anon;
grant execute on function public.vm_chat(text,jsonb) to authenticated;
commit;
