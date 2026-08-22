-- Sila's Kitchen and More
-- Order -> WhatsApp notification foundation
--
-- Run this in Supabase SQL Editor AFTER deploying the
-- whatsapp-order-notifier Edge Function.
--
-- This migration is intentionally defensive: it creates the message log
-- only if it does not already exist and adds the INSERT trigger function.

create table if not exists public.whatsapp_messages (
  id uuid primary key default gen_random_uuid(),
  order_id uuid null references public.orders(id) on delete set null,
  direction text not null check (direction in ('inbound','outbound')),
  channel text not null default 'whatsapp',
  recipient_phone text,
  sender_phone text,
  message_type text,
  message_body text,
  provider_message_id text,
  status text not null default 'queued',
  error_message text,
  created_at timestamptz not null default now()
);

create index if not exists whatsapp_messages_order_id_idx
  on public.whatsapp_messages(order_id);

create index if not exists whatsapp_messages_provider_message_id_idx
  on public.whatsapp_messages(provider_message_id);

-- The Database Webhook should POST to:
-- https://<PROJECT-REF>.supabase.co/functions/v1/whatsapp-order-notifier
-- and include:
-- x-whatsapp-internal-secret: <same value as the function secret>
--
-- Recommended webhook event:
-- public.orders -> INSERT
--
-- The webhook itself is configured from Supabase Dashboard:
-- Database > Webhooks > Create webhook > orders > INSERT.
--
-- Do NOT put the WhatsApp access token in this SQL file.

comment on table public.whatsapp_messages is
  'Operational WhatsApp message log for Sila order workflow.';
