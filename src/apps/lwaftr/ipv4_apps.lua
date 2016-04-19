module(..., package.seeall)

local arp = require("apps.lwaftr.arp")
local constants = require("apps.lwaftr.constants")
local fragmentv4 = require("apps.lwaftr.fragmentv4")
local lwutil = require("apps.lwaftr.lwutil")
local icmp = require("apps.lwaftr.icmp")

local ethernet = require("lib.protocol.ethernet")
local ipv4 = require("lib.protocol.ipv4")
local checksum = require("lib.checksum")
local packet = require("core.packet")
local bit = require("bit")
local ffi = require("ffi")

local receive, transmit = link.receive, link.transmit
local rd16, wr16, rd32, wr32 = lwutil.rd16, lwutil.wr16, lwutil.rd32, lwutil.wr32
local get_ihl_from_offset, htons = lwutil.get_ihl_from_offset, lwutil.htons
local is_fragment = fragmentv4.is_fragment

local n_ethertype_ipv4 = constants.n_ethertype_ipv4
local o_ipv4_identification = constants.o_ipv4_identification
local o_ipv4_src_addr = constants.o_ipv4_src_addr
local o_ipv4_dst_addr = constants.o_ipv4_dst_addr

local ethernet_header_size = constants.ethernet_header_size
local o_ipv4_ver_and_ihl = ethernet_header_size + constants.o_ipv4_ver_and_ihl
local o_ipv4_checksum = ethernet_header_size + constants.o_ipv4_checksum
local o_icmpv4_msg_type_sans_ihl = ethernet_header_size + constants.o_icmpv4_msg_type
local o_icmpv4_checksum_sans_ihl = ethernet_header_size + constants.o_icmpv4_checksum
local icmpv4_echo_request = constants.icmpv4_echo_request
local icmpv4_echo_reply = constants.icmpv4_echo_reply

Reassembler = {}
Fragmenter = {}
ARP = {}
ICMPEcho = {}

function Reassembler:new(conf)
   local o = setmetatable({}, {__index=Reassembler})
   o.conf = conf

   if conf.vlan_tagging then
      o.l2_size = ethernet_header_size + 4
      o.ethertype_offset = constants.o_ethernet_ethertype + 4
   else
      o.l2_size = ethernet_header_size
      o.ethertype_offset = constants.o_ethernet_ethertype
   end
   o.fragment_cache = {}
   return o
end

function Reassembler:key_frag(frag)
   local frag_id = rd16(frag.data + self.l2_size + o_ipv4_identification)
   local src_ip = ffi.string(frag.data + self.l2_size + o_ipv4_src_addr, 4)
   local dst_ip = ffi.string(frag.data + self.l2_size + o_ipv4_dst_addr, 4)
   return frag_id .. "|" .. src_ip .. dst_ip
end

function Reassembler:cache_fragment(frag)
   local cache = self.fragment_cache
   local key = self:key_frag(frag)
   cache[key] = cache[key] or {}
   table.insert(cache[key], frag)
   return cache[key]
end

function Reassembler:clean_fragment_cache(frags)
   local key = self:key_frag(frags[1])
   self.fragment_cache[key] = nil
   for _, p in ipairs(frags) do
      packet.free(p)
   end
end

local function is_ipv4(pkt, ethertype_offset)
   return rd16(pkt.data + ethertype_offset) == n_ethertype_ipv4
end

function Reassembler:push ()
   local input, output = self.input.input, self.output.output
   local errors = self.output.errors

   local l2_size = self.l2_size
   local ethertype_offset = self.ethertype_offset

   for _=1,math.min(link.nreadable(input), link.nwritable(output)) do
      local pkt = receive(input)
      if is_ipv4(pkt, ethertype_offset) and is_fragment(pkt, l2_size) then
         local frags = self:cache_fragment(pkt)
         local status, maybe_pkt = fragmentv4.reassemble(frags, l2_size)
         if status == fragmentv4.REASSEMBLE_OK then
            -- Reassembly was successful
            self:clean_fragment_cache(frags)
            transmit(output, maybe_pkt)
         elseif status == fragmentv4.REASSEMBLE_MISSING_FRAGMENT then
            -- Nothing to do, just wait.
         elseif status == fragmentv4.REASSEMBLE_INVALID then
            self:clean_fragment_cache(frags)
            if maybe_pkt then -- This is an ICMP packet
               transmit(errors, maybe_pkt)
            end
         else -- unreachable
            packet.free(pkt)
         end
      else
         -- Forward all packets that aren't IPv4 fragments.
         transmit(output, pkt)
      end
   end
end

function Fragmenter:new(conf)
   local o = setmetatable({}, {__index=Fragmenter})
   o.conf = conf

   o.mtu = assert(conf.mtu)

   if conf.vlan_tagging then
      o.l2_size = ethernet_header_size + 4
      o.ethertype_offset = constants.o_ethernet_ethertype + 4
   else
      o.l2_size = ethernet_header_size
      o.ethertype_offset = constants.o_ethernet_ethertype
   end

   return o
end

function Fragmenter:push ()
   local input, output = self.input.input, self.output.output
   local errors = self.output.errors

   local l2_size, mtu = self.l2_size, self.mtu
   local ethertype_offset = self.ethertype_offset

   for _=1,link.nreadable(input) do
      local pkt = receive(input)
      if pkt.length > mtu + l2_size and is_ipv4(pkt, ethertype_offset) then
         local status, frags = fragmentv4.fragment(pkt, l2_size, mtu)
         if status == fragmentv4.FRAGMENT_OK then
            for i=1,#frags do transmit(output, frags[i]) end
         else
            -- TODO: send ICMPv4 info if allowed by policy
            packet.free(pkt)
         end
      else
         transmit(output, pkt)
      end
   end
end

-- TODO: handle any ARP retry policy code here
function ARP:new(conf)
   local o = setmetatable({}, {__index=ARP})
   o.conf = conf
   -- TODO: verify that the src and dst ipv4 addresses and src mac address
   -- have been provided, in pton format.
   if not conf.dst_eth then
      o.arp_request_pkt = arp.form_request(conf.src_eth, conf.src_ipv4, conf.dst_ipv4)
      o.do_arp_request = true
   else
      o.do_arp_request = false
   end
   o.dst_eth = conf.dst_eth -- intentionally nil if to request via ARP
   return o
end

function ARP:push()
   local isouth, osouth = self.input.south, self.output.south
   local inorth, onorth = self.input.north, self.output.north
   if self.do_arp_request then
      self.do_arp_request = false -- TODO: have retries, etc
      transmit(osouth, packet.clone(self.arp_request_pkt))
   end
   for _=1,link.nreadable(isouth) do
      local p = receive(isouth)
      if arp.is_arp(p) then
         if not self.dst_eth and arp.is_arp_reply(p) then
            local dst_ethernet = arp.get_isat_ethernet(p, self.conf.dst_ipv4)
            if dst_ethernet then
               self.dst_eth = dst_ethernet
            end
            packet.free(p)
         elseif arp.is_arp_request(p, self.conf.src_ipv4) then
            local arp_reply_pkt = arp.form_reply(self.conf.src_eth, self.conf.src_ipv4, p)
            if arp_reply_pkt then
               transmit(osouth, arp_reply_pkt)
            end
            packet.free(p)
         else -- incoming ARP that isn't handled; drop it silently
            packet.free(p)
         end
      else
         transmit(onorth, p)
      end
   end

   for _=1,link.nreadable(inorth) do
      local p = receive(inorth)
      if not self.dst_eth then
         -- drop all southbound packets until the next hop's ethernet address is known
         packet.free(p)
      else
         lwutil.set_dst_ethernet(p, self.dst_eth)
         transmit(osouth, p)
      end
   end
end

function ICMPEcho:new(conf)
   local addresses = {}
   if conf.address then
      addresses[rd32(conf.address)] = true
   end
   if conf.addresses then
      for _, v in ipairs(conf.addresses) do
         addresses[rd32(v)] = true
      end
   end
   return setmetatable({addresses = addresses}, {__index = ICMPEcho})
end

function ICMPEcho:push()
   local l_in, l_out, l_reply = self.input.south, self.output.north, self.output.south

   for _ = 1, math.min(link.nreadable(l_in), link.nwritable(l_out)) do
      local out, pkt = l_out, receive(l_in)

      if icmp.is_icmpv4_message(pkt, icmpv4_echo_request, 0) then
         local pkt_ipv4 = ipv4:new_from_mem(pkt.data + ethernet_header_size,
                                            pkt.length - ethernet_header_size)
         local pkt_ipv4_dst = rd32(pkt_ipv4:dst())
         if self.addresses[pkt_ipv4_dst] then
            ethernet:new_from_mem(pkt.data, ethernet_header_size):swap()

            -- Swap IP source/destination
            pkt_ipv4:dst(pkt_ipv4:src())
            wr32(pkt_ipv4:src(), pkt_ipv4_dst)

            -- Change ICMP message type
            local ihl = get_ihl_from_offset(pkt, o_ipv4_ver_and_ihl)
            pkt.data[o_icmpv4_msg_type_sans_ihl + ihl] = icmpv4_echo_reply

            -- Clear out flags
            pkt_ipv4:flags(0)

            -- Recalculate checksums
            wr16(pkt.data + o_icmpv4_checksum_sans_ihl + ihl, 0)
            local icmp_offset = ethernet_header_size + ihl
            local csum = checksum.ipsum(pkt.data + icmp_offset, pkt.length - icmp_offset, 0)
            wr16(pkt.data + o_icmpv4_checksum_sans_ihl + ihl, htons(csum))
            wr16(pkt.data + o_ipv4_checksum, 0)
            pkt_ipv4:checksum()

            out = l_reply
         end
      end

      transmit(out, pkt)
   end

   l_in, l_out = self.input.north, self.output.south
   for _ = 1, math.min(link.nreadable(l_in), link.nwritable(l_out)) do
      transmit(l_out, receive(l_in))
   end
end