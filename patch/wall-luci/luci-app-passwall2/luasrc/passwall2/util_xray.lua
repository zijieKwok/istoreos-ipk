module("luci.passwall2.util_xray", package.seeall)
local api = require "luci.passwall2.api"
local uci = api.uci
local sys = api.sys
local jsonc = api.jsonc
local appname = api.appname
local fs = api.fs
local CACHE_PATH = api.CACHE_PATH

local new_port

local function get_new_port()
	if new_port then
		new_port = tonumber(sys.exec(string.format("echo -n $(/usr/share/%s/app.sh get_new_port %s tcp)", appname, new_port + 1)))
	else
		new_port = tonumber(sys.exec(string.format("echo -n $(/usr/share/%s/app.sh get_new_port auto tcp)", appname)))
	end
	return new_port
end

local function get_noise_packets()
	local noises = {}
	uci:foreach(appname, "xray_noise_packets", function(n)
		local noise = (n.enabled == "1") and {
			type = n.type,
			packet = n.packet,
			delay = string.find(n.delay, "-") and n.delay or tonumber(n.delay)
		} or nil
		table.insert(noises, noise)
	end)
	if #noises == 0 then noises = nil end
	return noises
end

local function get_domain_excluded()
	local path = string.format("/usr/share/%s/domains_excluded", appname)
	local content = fs.readfile(path)
	if not content then return nil end
	local hosts = {}
	string.gsub(content, '[^' .. "\n" .. ']+', function(w)
		local s = w:gsub("^%s*(.-)%s*$", "%1") -- Trim
		if s == "" then return end
		if s:find("#") and s:find("#") == 1 then return end
		if not s:find("#") or s:find("#") ~= 1 then table.insert(hosts, s) end
	end)
	if #hosts == 0 then hosts = nil end
	return hosts
end

function gen_outbound(flag, node, tag, proxy_table)
	local result = nil
	if node then
		local node_id = node[".name"]
		if tag == nil then
			tag = node_id
		end

		local proxy_tag = nil
		local fragment = nil
		local noise = nil
		if proxy_table ~= nil and type(proxy_table) == "table" then
			proxy_tag = proxy_table.tag or nil
			fragment = proxy_table.fragment or nil
			noise = proxy_table.noise or nil
		end

		if node.type ~= "Xray" then
			local relay_port = node.port
			new_port = get_new_port()
			local config_file = string.format("%s_%s_%s.json", flag, tag, new_port)
			if tag and node_id and tag ~= node_id then
				config_file = string.format("%s_%s_%s_%s.json", flag, tag, node_id, new_port)
			end
			sys.call(string.format('/usr/share/%s/app.sh run_socks "%s"> /dev/null',
				appname,
				string.format("flag=%s node=%s bind=%s socks_port=%s config_file=%s relay_port=%s",
					new_port, --flag
					node_id, --node
					"127.0.0.1", --bind
					new_port, --socks port
					config_file, --config file
					(proxy_tag and relay_port) and tostring(relay_port) or "" --relay port
					)
				)
			)
			node = {}
			node.protocol = "socks"
			node.transport = "tcp"
			node.address = "127.0.0.1"
			node.port = new_port
			node.stream_security = "none"
		else
			if node.flow == "xtls-rprx-vision" then
			else
				if proxy_tag then
					node.proxySettings = {
						tag = proxy_tag,
						transportLayer = true
					}
				end
			end
		end
		
		if node.type == "Xray" then
			if node.tls and node.tls == "1" then
				node.stream_security = "tls"
				if node.reality and node.reality == "1" then
					node.stream_security = "reality"
				end
			end
		end

		if node.protocol == "wireguard" and node.wireguard_reserved then
			local bytes = {}
			if not node.wireguard_reserved:match("[^%d,]+") then
				node.wireguard_reserved:gsub("%d+", function(b)
					bytes[#bytes + 1] = tonumber(b)
				end)
			else
				local result = api.bin.b64decode(node.wireguard_reserved)
				for i = 1, #result do
					bytes[i] = result:byte(i)
				end
			end
			node.wireguard_reserved = #bytes > 0 and bytes or nil
		end

		result = {
			_id = node_id,
			_flag = flag,
			_flag_proxy_tag = proxy_tag,
			tag = tag,
			proxySettings = node.proxySettings or nil,
			protocol = node.protocol,
			mux = {
				enabled = (node.mux == "1" or node.xmux == "1") and true or false,
				concurrency = (node.mux == "1" and ((node.mux_concurrency) and tonumber(node.mux_concurrency) or 8)) or ((node.xmux == "1") and -1) or nil,
				xudpConcurrency = (node.xmux == "1" and ((node.xudp_concurrency) and tonumber(node.xudp_concurrency) or 8)) or nil
			} or nil,
			-- 底层传输配置
			streamSettings = (node.streamSettings or node.protocol == "vmess" or node.protocol == "vless" or node.protocol == "socks" or node.protocol == "shadowsocks" or node.protocol == "trojan") and {
				sockopt = {
					mark = 255,
					tcpMptcp = (node.tcpMptcp == "1") and true or nil,
					tcpNoDelay = (node.tcpNoDelay == "1") and true or nil,
					dialerProxy = (fragment or noise) and "dialerproxy" or nil
				},
				network = node.transport,
				security = node.stream_security,
				tlsSettings = (node.stream_security == "tls") and {
					serverName = node.tls_serverName,
					allowInsecure = (node.tls_allowInsecure == "1") and true or false,
					fingerprint = (node.type == "Xray" and node.utls == "1" and node.fingerprint and node.fingerprint ~= "") and node.fingerprint or nil
				} or nil,
				realitySettings = (node.stream_security == "reality") and {
					serverName = node.tls_serverName,
					publicKey = node.reality_publicKey,
					shortId = node.reality_shortId or "",
					spiderX = node.reality_spiderX or "/",
					fingerprint = (node.type == "Xray" and node.fingerprint and node.fingerprint ~= "") and node.fingerprint or "chrome"
				} or nil,
				rawSettings = ((node.transport == "raw" or node.transport == "tcp") and node.protocol ~= "socks") and {
					header = {
						type = node.tcp_guise or "none",
						request = (node.tcp_guise == "http") and {
							path = node.tcp_guise_http_path or {"/"},
							headers = {
								Host = node.tcp_guise_http_host or {}
							}
						} or nil
					}
				} or nil,
				kcpSettings = (node.transport == "mkcp") and {
					mtu = tonumber(node.mkcp_mtu),
					tti = tonumber(node.mkcp_tti),
					uplinkCapacity = tonumber(node.mkcp_uplinkCapacity),
					downlinkCapacity = tonumber(node.mkcp_downlinkCapacity),
					congestion = (node.mkcp_congestion == "1") and true or false,
					readBufferSize = tonumber(node.mkcp_readBufferSize),
					writeBufferSize = tonumber(node.mkcp_writeBufferSize),
					seed = (node.mkcp_seed and node.mkcp_seed ~= "") and node.mkcp_seed or nil,
					header = {type = node.mkcp_guise}
				} or nil,
				wsSettings = (node.transport == "ws") and {
					path = node.ws_path or "/",
					host = node.ws_host or nil,
					maxEarlyData = tonumber(node.ws_maxEarlyData) or nil,
					earlyDataHeaderName = (node.ws_earlyDataHeaderName) and node.ws_earlyDataHeaderName or nil,
					heartbeatPeriod = tonumber(node.ws_heartbeatPeriod) or nil
				} or nil,
				dsSettings = (node.transport == "ds") and
					{path = node.ds_path} or nil,
				quicSettings = (node.transport == "quic") and {
					security = node.quic_security,
					key = node.quic_key,
					header = {type = node.quic_guise}
				} or nil,
				grpcSettings = (node.transport == "grpc") and {
					serviceName = node.grpc_serviceName,
					multiMode = (node.grpc_mode == "multi") and true or nil,
					idle_timeout = tonumber(node.grpc_idle_timeout) or nil,
					health_check_timeout = tonumber(node.grpc_health_check_timeout) or nil,
					permit_without_stream = (node.grpc_permit_without_stream == "1") and true or nil,
					initial_windows_size = tonumber(node.grpc_initial_windows_size) or nil
				} or nil,
				httpupgradeSettings = (node.transport == "httpupgrade") and {
					path = node.httpupgrade_path or "/",
					host = node.httpupgrade_host
				} or nil,
				xhttpSettings = (node.transport == "xhttp" or node.transport == "splithttp") and {
					mode = node.xhttp_mode or "auto",
					path = node.xhttp_path or node.splithttp_path or "/",
					host = node.xhttp_host or node.splithttp_host,
					-- 如果包含 "extra" 节，取 "extra" 内的内容，否则直接赋值给 extra
					extra = node.xhttp_extra and (function()
						local success, parsed = pcall(jsonc.parse, node.xhttp_extra)
							if success then
								return parsed.extra or parsed
							else
								return nil
							end
						end)() or nil
				} or nil,
			} or nil,
			settings = {
				vnext = (node.protocol == "vmess" or node.protocol == "vless") and {
					{
						address = node.address,
						port = tonumber(node.port),
						users = {
							{
								id = node.uuid,
								level = 0,
								security = (node.protocol == "vmess") and node.security or nil,
								encryption = node.encryption or "none",
								flow = (node.protocol == "vless" and node.tls == "1" and (node.transport == "raw" or node.transport == "tcp") and node.flow and node.flow ~= "") and node.flow or nil

							}
						}
					}
				} or nil,
				servers = (node.protocol == "socks" or node.protocol == "http" or node.protocol == "shadowsocks" or node.protocol == "trojan") and {
					{
						address = node.address,
						port = tonumber(node.port),
						method = (node.method == "chacha20-ietf-poly1305" and "chacha20-poly1305") or
							(node.method == "xchacha20-ietf-poly1305" and "xchacha20-poly1305") or
							(node.method ~= "" and node.method) or nil,
						ivCheck = (node.protocol == "shadowsocks") and node.iv_check == "1" or nil,
						uot = (node.protocol == "shadowsocks") and node.uot == "1" or nil,
						password = node.password or "",
						users = (node.username and node.password) and {
							{
								user = node.username,
								pass = node.password
							}
						} or nil
					}
				} or nil,
				address = (node.protocol == "wireguard" and node.wireguard_local_address) and node.wireguard_local_address or nil,
				secretKey = (node.protocol == "wireguard") and node.wireguard_secret_key or nil,
				peers = (node.protocol == "wireguard") and {
					{
						publicKey = node.wireguard_public_key,
						endpoint = node.address .. ":" .. node.port,
						preSharedKey = node.wireguard_preSharedKey,
						keepAlive = node.wireguard_keepAlive and tonumber(node.wireguard_keepAlive) or nil
					}
				} or nil,
				mtu = (node.protocol == "wireguard" and node.wireguard_mtu) and tonumber(node.wireguard_mtu) or nil,
				reserved = (node.protocol == "wireguard" and node.wireguard_reserved) and node.wireguard_reserved or nil
			}
		}

		if node.protocol == "wireguard" then
			result.settings.kernelMode = false
		end

		local alpn = {}
		if node.alpn and node.alpn ~= "default" then
			string.gsub(node.alpn, '[^' .. "," .. ']+', function(w)
				table.insert(alpn, w)
			end)
		end
		if alpn and #alpn > 0 then
			if result.streamSettings.tlsSettings then
				result.streamSettings.tlsSettings.alpn = alpn
			end
		end

	end
	return result
end

function gen_config_server(node)
	local settings = nil
	local routing = nil
	local outbounds = {
		{protocol = "freedom", tag = "direct"}, {protocol = "blackhole", tag = "blocked"}
	}

	if node.protocol == "vmess" or node.protocol == "vless" then
		if node.uuid then
			local clients = {}
			for i = 1, #node.uuid do
				clients[i] = {
					id = node.uuid[i],
					flow = ("vless" == node.protocol and "1" == node.tls and "raw" == node.transport and node.flow and node.flow ~= "") and node.flow or nil
				}
			end
			settings = {
				clients = clients,
				decryption = node.decryption or "none"
			}
		end
	elseif node.protocol == "socks" then
		settings = {
			udp = ("1" == node.udp_forward) and true or false,
			auth = ("1" == node.auth) and "password" or "noauth",
			accounts = ("1" == node.auth) and {
				{
					user = node.username,
					pass = node.password
				}
			} or nil
		}
	elseif node.protocol == "http" then
		settings = {
			allowTransparent = false,
			accounts = ("1" == node.auth) and {
				{
					user = node.username,
					pass = node.password
				}
			} or nil
		}
		node.transport = "tcp"
		node.tcp_guise = "none"
	elseif node.protocol == "shadowsocks" then
		settings = {
			method = node.method,
			password = node.password,
			ivCheck = ("1" == node.iv_check) and true or false,
			network = node.ss_network or "TCP,UDP"
		}
	elseif node.protocol == "trojan" then
		if node.uuid then
			local clients = {}
			for i = 1, #node.uuid do
				clients[i] = {
					password = node.uuid[i]
				}
			end
			settings = {
				clients = clients
			}
		end
	elseif node.protocol == "dokodemo-door" then
		settings = {
			network = node.d_protocol,
			address = node.d_address,
			port = tonumber(node.d_port)
		}
	end

	if node.fallback and node.fallback == "1" then
		local fallbacks = {}
		for i = 1, #node.fallback_list do
			local fallbackStr = node.fallback_list[i]
			if fallbackStr then
				local tmp = {}
				string.gsub(fallbackStr, '[^' .. "," .. ']+', function(w)
					table.insert(tmp, w)
				end)
				local dest = tmp[1] or ""
				local path = tmp[2]
				if dest:find("%.") then
				else
					dest = tonumber(dest)
				end
				fallbacks[i] = {
					path = path,
					dest = dest,
					xver = 1
				}
			end
		end
		settings.fallbacks = fallbacks
	end

	routing = {
		domainStrategy = "IPOnDemand",
		rules = {
			{
				ip = {"10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16"},
				outboundTag = (node.accept_lan == nil or node.accept_lan == "0") and "blocked" or "direct"
			}
		}
	}

	if node.outbound_node then
		local outbound = nil
		if node.outbound_node == "_iface" and node.outbound_node_iface then
			outbound = {
				protocol = "freedom",
				tag = "outbound",
				streamSettings = {
					sockopt = {
						mark = 255,
						interface = node.outbound_node_iface
					}
				}
			}
			sys.call(string.format("mkdir -p %s && touch %s/%s", api.TMP_IFACE_PATH, api.TMP_IFACE_PATH, node.outbound_node_iface))
		else
			local outbound_node_t = uci:get_all("passwall2", node.outbound_node)
			if node.outbound_node == "_socks" or node.outbound_node == "_http" then
				outbound_node_t = {
					type = node.type,
					protocol = node.outbound_node:gsub("_", ""),
					transport = "tcp",
					address = node.outbound_node_address,
					port = node.outbound_node_port,
					username = (node.outbound_node_username and node.outbound_node_username ~= "") and node.outbound_node_username or nil,
					password = (node.outbound_node_password and node.outbound_node_password ~= "") and node.outbound_node_password or nil,
				}
			end
			outbound = require("luci.passwall2.util_xray").gen_outbound(nil, outbound_node_t, "outbound")
		end
		if outbound then
			table.insert(outbounds, 1, outbound)
		end
	end

	local config = {
		log = {
			loglevel = ("1" == node.log) and node.loglevel or "none"
		},
		-- 传入连接
		inbounds = {
			{
				listen = (node.bind_local == "1") and "127.0.0.1" or nil,
				port = tonumber(node.port),
				protocol = node.protocol,
				settings = settings,
				streamSettings = {
					network = node.transport,
					security = "none",
					tlsSettings = ("1" == node.tls) and {
						disableSystemRoot = false,
						certificates = {
							{
								certificateFile = node.tls_certificateFile,
								keyFile = node.tls_keyFile
							}
						}
					} or nil,
					rawSettings = (node.transport == "raw" or node.transport == "tcp") and {
						header = {
							type = node.tcp_guise,
							request = (node.tcp_guise == "http") and {
								path = node.tcp_guise_http_path or {"/"},
								headers = {
									Host = node.tcp_guise_http_host or {}
								}
							} or nil
						}
					} or nil,
					kcpSettings = (node.transport == "mkcp") and {
						mtu = tonumber(node.mkcp_mtu),
						tti = tonumber(node.mkcp_tti),
						uplinkCapacity = tonumber(node.mkcp_uplinkCapacity),
						downlinkCapacity = tonumber(node.mkcp_downlinkCapacity),
						congestion = (node.mkcp_congestion == "1") and true or false,
						readBufferSize = tonumber(node.mkcp_readBufferSize),
						writeBufferSize = tonumber(node.mkcp_writeBufferSize),
						seed = (node.mkcp_seed and node.mkcp_seed ~= "") and node.mkcp_seed or nil,
						header = {type = node.mkcp_guise}
					} or nil,
					wsSettings = (node.transport == "ws") and {
						host = node.ws_host or nil,
						path = node.ws_path
					} or nil,
					dsSettings = (node.transport == "ds") and {
						path = node.ds_path
					} or nil,
					quicSettings = (node.transport == "quic") and {
						security = node.quic_security,
						key = node.quic_key,
						header = {type = node.quic_guise}
					} or nil,
					grpcSettings = (node.transport == "grpc") and {
						serviceName = node.grpc_serviceName
					} or nil,
					httpupgradeSettings = (node.transport == "httpupgrade") and {
						path = node.httpupgrade_path or "/",
						host = node.httpupgrade_host
					} or nil,
					xhttpSettings = (node.transport == "xhttp") and {
						path = node.xhttp_path or "/",
						host = node.xhttp_host,
						maxUploadSize = node.xhttp_maxuploadsize,
						maxConcurrentUploads = node.xhttp_maxconcurrentuploads
					} or nil,
					sockopt = {
						acceptProxyProtocol = (node.acceptProxyProtocol and node.acceptProxyProtocol == "1") and true or false
					}
				}
			}
		},
		-- 传出连接
		outbounds = outbounds,
		routing = routing
	}

	local alpn = {}
	if node.alpn then
		string.gsub(node.alpn, '[^' .. "," .. ']+', function(w)
			table.insert(alpn, w)
		end)
	end
	if alpn and #alpn > 0 then
		if config.inbounds[1].streamSettings.tlsSettings then
			config.inbounds[1].streamSettings.tlsSettings.alpn = alpn
		end
	end

	if "1" == node.tls then
		config.inbounds[1].streamSettings.security = "tls"
		if "1" == node.reality then
			config.inbounds[1].streamSettings.tlsSettings = nil
			config.inbounds[1].streamSettings.security = "reality"
			config.inbounds[1].streamSettings.realitySettings = {
				show = false,
				dest = node.reality_dest,
				serverNames = {
					node.reality_serverNames
				},
				privateKey = node.reality_private_key,
				shortIds = node.reality_shortId or ""
			} or nil
		end
	end

	return config
end

function gen_config(var)
	local flag = var["-flag"]
	local loglevel = var["-loglevel"] or "warning"
	local node_id = var["-node"]
	local server_host = var["-server_host"]
	local server_port = var["-server_port"]
	local tcp_proxy_way = var["-tcp_proxy_way"]
	local redir_port = var["-redir_port"]
	local local_socks_address = var["-local_socks_address"] or "0.0.0.0"
	local local_socks_port = var["-local_socks_port"]
	local local_socks_username = var["-local_socks_username"]
	local local_socks_password = var["-local_socks_password"]
	local local_http_address = var["-local_http_address"] or "0.0.0.0"
	local local_http_port = var["-local_http_port"]
	local local_http_username = var["-local_http_username"]
	local local_http_password = var["-local_http_password"]
	local dns_listen_port = var["-dns_listen_port"]
	local direct_dns_udp_server = var["-direct_dns_udp_server"]
	local direct_dns_udp_port = var["-direct_dns_udp_port"]
	local direct_dns_query_strategy = var["-direct_dns_query_strategy"]
	local direct_ipset = var["-direct_ipset"]
	local direct_nftset = var["-direct_nftset"]
	local remote_dns_udp_server = var["-remote_dns_udp_server"]
	local remote_dns_udp_port = var["-remote_dns_udp_port"]
	local remote_dns_tcp_server = var["-remote_dns_tcp_server"]
	local remote_dns_tcp_port = var["-remote_dns_tcp_port"]
	local remote_dns_doh_url = var["-remote_dns_doh_url"]
	local remote_dns_doh_host = var["-remote_dns_doh_host"]
	local remote_dns_doh_ip = var["-remote_dns_doh_ip"]
	local remote_dns_doh_port = var["-remote_dns_doh_port"]
	local remote_dns_fake = var["-remote_dns_fake"]
	local remote_dns_query_strategy = var["-remote_dns_query_strategy"]
	local remote_dns_detour = var["-remote_dns_detour"]
	local dns_cache = var["-dns_cache"]

	local dns_domain_rules = {}
	local dns = nil
	local fakedns = nil
	local inbounds = {}
	local outbounds = {}
	local routing = nil
	local observatory = nil
	local COMMON = {}

	local CACHE_TEXT_FILE = CACHE_PATH .. "/cache_" .. flag .. ".txt"

	local xray_settings = uci:get_all(appname, "@global_xray[0]") or {}

	local node = node_id and uci:get_all(appname, node_id) or nil
	local balancers = {}
	local rules = {}

	if local_socks_port then
		local inbound = {
			tag = "socks-in",
			listen = local_socks_address,
			port = tonumber(local_socks_port),
			protocol = "socks",
			settings = {auth = "noauth", udp = true},
			sniffing = {
				enabled = xray_settings.sniffing_override_dest == "1" or node.protocol == "_shunt"
			}
		}
		if inbound.sniffing.enabled == true then
			inbound.sniffing.destOverride = {"http", "tls", "quic"}
			inbound.sniffing.routeOnly = xray_settings.sniffing_override_dest ~= "1" or nil
			inbound.sniffing.domainsExcluded = xray_settings.sniffing_override_dest == "1" and get_domain_excluded() or nil
		end
		if local_socks_username and local_socks_password and local_socks_username ~= "" and local_socks_password ~= "" then
			inbound.settings.auth = "password"
			inbound.settings.accounts = {
				{
					user = local_socks_username,
					pass = local_socks_password
				}
			}
		end
		table.insert(inbounds, inbound)
	end

	if local_http_port then
		local inbound = {
			listen = local_http_address,
			port = tonumber(local_http_port),
			protocol = "http",
			settings = {allowTransparent = false}
		}
		if local_http_username and local_http_password and local_http_username ~= "" and local_http_password ~= "" then
			inbound.settings.accounts = {
				{
					user = local_http_username,
					pass = local_http_password
				}
			}
		end
		table.insert(inbounds, inbound)
	end

	if redir_port then
		local inbound = {
			port = tonumber(redir_port),
			protocol = "dokodemo-door",
			settings = {network = "tcp,udp", followRedirect = true},
			streamSettings = {sockopt = {tproxy = "tproxy"}},
			sniffing = {
				enabled = xray_settings.sniffing_override_dest == "1" or node.protocol == "_shunt"
			}
		}
		if inbound.sniffing.enabled == true then
			inbound.sniffing.destOverride = {"http", "tls", "quic"}
			inbound.sniffing.metadataOnly = false
			inbound.sniffing.routeOnly = xray_settings.sniffing_override_dest ~= "1" or nil
			inbound.sniffing.domainsExcluded = xray_settings.sniffing_override_dest == "1" and get_domain_excluded() or nil
		end
		if remote_dns_fake then
			inbound.sniffing.enabled = true
			if not inbound.sniffing.destOverride then
				inbound.sniffing.destOverride = {"fakedns"}
				inbound.sniffing.metadataOnly = true
			else
				table.insert(inbound.sniffing.destOverride, "fakedns")
				inbound.sniffing.metadataOnly = false
			end
		end

		local tcp_inbound = api.clone(inbound)
		tcp_inbound.tag = "tcp_redir"
		tcp_inbound.settings.network = "tcp"
		tcp_inbound.streamSettings.sockopt.tproxy = tcp_proxy_way
		table.insert(inbounds, tcp_inbound)

		local udp_inbound = api.clone(inbound)
		udp_inbound.tag = "udp_redir"
		udp_inbound.settings.network = "udp"
		table.insert(inbounds, udp_inbound)
	end

	local function get_balancer_tag(_node_id)
		return "balancer-" .. _node_id
	end

	local function gen_loopback(outboundTag, dst_node_id)
		if not outboundTag then return nil end
		local inboundTag = dst_node_id and "loop-in-" .. dst_node_id or outboundTag .. "-lo"
		table.insert(outbounds, {
			protocol = "loopback",
			tag = outboundTag,
			settings = { inboundTag = inboundTag }
		})
		return inboundTag
	end

	local function gen_balancer(_node, loopback_tag)
		local balancer_id = _node[".name"]
		local balancer_tag = "balancer-" .. balancer_id
		local loopback_dst = balancer_id -- route destination for the loopback outbound
		if not loopback_tag or loopback_tag == "" then loopback_tag = balancer_id end
		-- existing balancer
		for _, v in ipairs(balancers) do
			if v.tag == balancer_tag then
				gen_loopback(loopback_tag, loopback_dst)
				return balancer_tag
			end
		end
		-- new balancer
		local blc_nodes = _node.balancing_node
		local valid_nodes = {}
		for i = 1, #blc_nodes do
			local blc_node_id = blc_nodes[i]
			local blc_node_tag = "blc-" .. blc_node_id
			local is_new_blc_node = true
			for _, outbound in ipairs(outbounds) do
				if outbound.tag:find("^" .. blc_node_tag) == 1 then
					is_new_blc_node = false
					valid_nodes[#valid_nodes + 1] = outbound.tag
					break
				end
			end
			if is_new_blc_node then
				local blc_node = uci:get_all(appname, blc_node_id)
				local outbound = gen_outbound(flag, blc_node, blc_node_tag, { fragment = xray_settings.fragment == "1" or nil, noise = xray_settings.noise == "1" or nil })
				if outbound then
					outbound.tag = outbound.tag .. ":" .. blc_node.remarks
					table.insert(outbounds, outbound)
					valid_nodes[#valid_nodes + 1] = outbound.tag
				end
			end
		end
		if #valid_nodes == 0 then return nil end

		-- fallback node
		local fallback_node_tag = nil
		local fallback_node_id = _node.fallback_node
		if not fallback_node_id or fallback_node_id == "" then fallback_node_id = nil end
		if fallback_node_id then
			local is_new_node = true
			for _, outbound in ipairs(outbounds) do
				if outbound.tag:find("^" .. fallback_node_id) == 1 then
					is_new_node = false
					fallback_node_tag = outbound.tag
					break
				end
			end
			if is_new_node then
				local fallback_node = uci:get_all(appname, fallback_node_id)
				if fallback_node.protocol ~= "_balancing" then
					local outbound = gen_outbound(flag, fallback_node, fallback_node_id, { fragment = xray_settings.fragment == "1" or nil, noise = xray_settings.noise == "1" or nil })
					if outbound then
						outbound.tag = outbound.tag .. ":" .. fallback_node.remarks
						table.insert(outbounds, outbound)
						fallback_node_tag = outbound.tag
					end
				end
			end
		end
		table.insert(balancers, {
			tag = balancer_tag,
			selector = valid_nodes,
			fallbackTag = fallback_node_tag,
			strategy = { type = _node.balancingStrategy or "random" }
		})
		if _node.balancingStrategy == "leastPing" or fallback_node_tag then
			if not observatory then
				observatory = {
					subjectSelector = { "blc-" },
					probeUrl = _node.useCustomProbeUrl and _node.probeUrl or nil,
					probeInterval = _node.probeInterval or "1m",
					enableConcurrency = true
				}
			end
		end
		local inbound_tag = gen_loopback(loopback_tag, loopback_dst)
		table.insert(rules, { inboundTag = { inbound_tag }, balancerTag = balancer_tag })
		return balancer_tag
	end
	
	local function set_outbound_detour(node, outbound, outbounds_table, shunt_rule_name)
		if not node or not outbound or not outbounds_table then return nil end
		local default_outTag = outbound.tag
		local last_insert_outbound

		if node.chain_proxy == "1" and node.preproxy_node then
			if outbound["_flag_proxy_tag"] then
				--Ignore
			else
				local preproxy_node = uci:get_all(appname, node.preproxy_node)
				if preproxy_node then
					local preproxy_outbound = gen_outbound(nil, preproxy_node)
					if preproxy_outbound then
						preproxy_outbound.tag = preproxy_node[".name"] .. ":" .. preproxy_node.remarks
						outbound.tag = preproxy_outbound.tag .. " -> " .. outbound.tag
						outbound.proxySettings = {
							tag = preproxy_outbound.tag,
							transportLayer = true
						}
						last_insert_outbound = preproxy_outbound
						default_outTag = outbound.tag
					end
				end
			end
		end
		if node.chain_proxy == "2" and node.to_node then
			local to_node = uci:get_all(appname, node.to_node)
			if to_node then
				local to_outbound = gen_outbound(nil, to_node)
				if to_outbound then
					if shunt_rule_name then
						to_outbound.tag = outbound.tag
						outbound.tag = node[".name"]
					else
						to_outbound.tag = outbound.tag .. " -> " .. to_outbound.tag
					end

					to_outbound.proxySettings = {
						tag = outbound.tag,
						transportLayer = true
					}
					table.insert(outbounds_table, to_outbound)
					default_outTag = to_outbound.tag
				end
			end
		end
		return default_outTag, last_insert_outbound
	end

	if node then
		if server_host and server_port then
			node.address = server_host
			node.port = server_port
		end
		if node.protocol == "_shunt" then
			local preproxy_rule_name = node.preproxy_enabled == "1" and "main" or nil
			local preproxy_tag = preproxy_rule_name
			local preproxy_node_id = node["main_node"]
			local preproxy_outbound_tag, preproxy_balancer_tag
			local preproxy_nodes

			local function gen_shunt_node(rule_name, _node_id)
				if not rule_name then return nil, nil end
				if not _node_id then _node_id = node[rule_name] end
				if _node_id == "_direct" then
					return "direct", nil
				elseif _node_id == "_blackhole" then
					return "blackhole", nil
				elseif _node_id == "_default" then
					return "default", nil
				elseif _node_id and _node_id:find("Socks_") then
					local socks_id = _node_id:sub(1 + #"Socks_")
					local socks_node = uci:get_all(appname, socks_id) or nil
					local socks_tag
					if socks_node then
						local _node = {
							type = "Xray",
							protocol = "socks",
							address = "127.0.0.1",
							port = socks_node.port,
							transport = "tcp",
							stream_security = "none"
						}
						local outbound = gen_outbound(flag, _node, rule_name)
						if outbound then
							if rule_name == "default" then
								table.insert(outbounds, 1, outbound)
							else
								table.insert(outbounds, outbound)
							end
							socks_tag = outbound.tag
						end
					end
					return socks_tag, nil
				elseif _node_id then
					local _node = uci:get_all(appname, _node_id)
					if not _node then return nil, nil end

					if api.is_normal_node(_node) then
						local use_proxy = preproxy_tag and node[rule_name .. "_proxy_tag"] == preproxy_rule_name and _node_id ~= preproxy_node_id
						if use_proxy and preproxy_balancer_tag and preproxy_nodes[_node_id] then use_proxy = false end
						local copied_outbound
						for index, value in ipairs(outbounds) do
							if value["_id"] == _node_id and value["_flag_proxy_tag"] == (use_proxy and preproxy_tag or nil) then
								copied_outbound = api.clone(value)
								break
							end
						end
						if copied_outbound then
							copied_outbound.tag = rule_name .. ":" .. _node.remarks
							table.insert(outbounds, copied_outbound)
							return copied_outbound.tag, nil
						else
							if use_proxy and (_node.type ~= "Xray" or _node.flow == "xtls-rprx-vision") then
								new_port = get_new_port()
								table.insert(inbounds, {
									tag = "proxy_" .. rule_name,
									listen = "127.0.0.1",
									port = new_port,
									protocol = "dokodemo-door",
									settings = {network = "tcp,udp", address = _node.address, port = tonumber(_node.port)}
								})
								if _node.tls_serverName == nil then
									_node.tls_serverName = _node.address
								end
								_node.address = "127.0.0.1"
								_node.port = new_port
								table.insert(rules, 1, {
									inboundTag = {"proxy_" .. rule_name},
									outboundTag = not preproxy_balancer_tag and preproxy_tag or nil,
									balancerTag = preproxy_balancer_tag
								})
							end
							local proxy_table = {
								tag = use_proxy and preproxy_tag or nil
							}
							if not proxy_table.tag then
								if xray_settings.fragment == "1" then
									proxy_table.fragment = true
								end
								if xray_settings.noise == "1" then
									proxy_table.noise = true
								end
							end
							local outbound = gen_outbound(flag, _node, rule_name, proxy_table)
							local outbound_tag
							if outbound then
								outbound.tag = outbound.tag .. ":" .. _node.remarks
								outbound_tag, last_insert_outbound = set_outbound_detour(_node, outbound, outbounds, rule_name)
								if rule_name == "default" then
									table.insert(outbounds, 1, outbound)
								else
									table.insert(outbounds, outbound)
								end
								if last_insert_outbound then
									table.insert(outbounds, last_insert_outbound)
								end
							end
							return outbound_tag, nil
						end
					elseif _node.protocol == "_balancing" then
						return nil, gen_balancer(_node, rule_name)
					elseif _node.protocol == "_iface" then
						local outbound_tag
						if _node.iface then
							local outbound = {
								protocol = "freedom",
								tag = rule_name,
								streamSettings = {
									sockopt = {
										mark = 255,
										interface = _node.iface
									}
								}
							}
							outbound_tag = outbound.tag
							table.insert(outbounds, outbound)
							sys.call(string.format("mkdir -p %s && touch %s/%s", api.TMP_IFACE_PATH, api.TMP_IFACE_PATH, _node.iface))
						end
						return outbound_tag, nil
					end
				end
			end

			if preproxy_tag and preproxy_node_id then
				preproxy_outbound_tag, preproxy_balancer_tag = gen_shunt_node(preproxy_rule_name, preproxy_node_id)
				if preproxy_balancer_tag then
					local _node_id = preproxy_node_id
					preproxy_nodes = {}
					while _node_id do
						_node = uci:get_all(appname, _node_id)
						if not _node then break end
						if _node.protocol ~= "_balancing" then
							preproxy_nodes[_node_id] = true
							break
						end
						local _blc_nodes = _node.balancing_node
						for i = 1, #_blc_nodes do preproxy_nodes[_blc_nodes[i]] = true end
						_node_id = _node.fallback_node
					end
				elseif preproxy_outbound_tag then
					preproxy_tag = preproxy_outbound_tag
				end
			end
			--default_node
			local default_node_id = node.default_node or "_direct"
			local default_outboundTag, default_balancerTag = gen_shunt_node("default", default_node_id)
			COMMON.default_outbound_tag = default_outboundTag
			COMMON.default_balancer_tag = default_balancerTag
			--shunt rule
			uci:foreach(appname, "shunt_rules", function(e)
				local outboundTag, balancerTag = gen_shunt_node(e[".name"])
				if outboundTag or balancerTag and e.remarks then
					if outboundTag == "default" then
						outboundTag = default_outboundTag
						balancerTag = default_balancerTag
					end
					local protocols = nil
					if e["protocol"] and e["protocol"] ~= "" then
						protocols = {}
						string.gsub(e["protocol"], '[^' .. " " .. ']+', function(w)
							table.insert(protocols, w)
						end)
					end
					local inboundTag = nil
					if e["inbound"] and e["inbound"] ~= "" then
						inboundTag = {}
						if e["inbound"]:find("tproxy") then
							if redir_port then
								table.insert(inboundTag, "tcp_redir")
								table.insert(inboundTag, "udp_redir")
							end
						end
						if e["inbound"]:find("socks") then
							if local_socks_port then
								table.insert(inboundTag, "socks-in")
							end
						end
					end
					local domains = nil
					if e.domain_list then
						local domain_table = {
							shunt_rule_name = e[".name"],
							outboundTag = outboundTag,
							balancerTag = balancerTag,
							domain = {},
						}
						domains = {}
						string.gsub(e.domain_list, '[^' .. "\r\n" .. ']+', function(w)
							if w:find("#") == 1 then return end
							table.insert(domains, w)
							table.insert(domain_table.domain, w)
						end)
						if outboundTag or balancerTag then
							table.insert(dns_domain_rules, api.clone(domain_table))
						end
						if #domains == 0 then domains = nil end
					end
					local ip = nil
					if e.ip_list then
						ip = {}
						string.gsub(e.ip_list, '[^' .. "\r\n" .. ']+', function(w)
							if w:find("#") == 1 then return end
							table.insert(ip, w)
						end)
						if #ip == 0 then ip = nil end
					end
					local source = nil
					if e.source then
						source = {}
						string.gsub(e.source, '[^' .. " " .. ']+', function(w)
							table.insert(source, w)
						end)
					end
					local rule = {
						ruleTag = e.remarks,
						inboundTag = inboundTag,
						outboundTag = outboundTag,
						balancerTag = balancerTag,
						network = e["network"] or "tcp,udp",
						source = source,
						sourcePort = e["sourcePort"] ~= "" and e["sourcePort"] or nil,
						port = e["port"] ~= "" and e["port"] or nil,
						protocol = protocols
					}
					if domains then
						local _rule = api.clone(rule)
						_rule.ruleTag = _rule.ruleTag .. " Domains"
						_rule.domains = domains
						table.insert(rules, _rule)
					end
					if ip then
						local _rule = api.clone(rule)
						_rule.ruleTag = _rule.ruleTag .. " IP"
						_rule.ip = ip
						table.insert(rules, _rule)
					end
					if not domains and not ip then
						table.insert(rules, rule)
					end
				end
			end)

			if default_balancerTag then
				table.insert(rules, {
					ruleTag = "default",
					balancerTag = default_balancerTag,
					network = "tcp,udp"
				})
			end

			routing = {
				domainStrategy = node.domainStrategy or "AsIs",
				domainMatcher = node.domainMatcher or "hybrid",
				balancers = #balancers > 0 and balancers or nil,
				rules = rules
			}
		elseif node.protocol == "_balancing" then
			if node.balancing_node then
				local balancer_tag = gen_balancer(node)
				if balancer_tag then
					table.insert(rules, { network = "tcp,udp", balancerTag = balancer_tag })
				end
				routing = {
					balancers = balancers,
					rules = rules
				}
				COMMON.default_balancer_tag = balancer_tag
			end
		elseif node.protocol == "_iface" then
			if node.iface then
				local outbound = {
					protocol = "freedom",
					tag = node.remarks or node_id,
					streamSettings = {
						sockopt = {
							mark = 255,
							interface = node.iface
						}
					}
				}
				table.insert(outbounds, outbound)
				COMMON.default_outbound_tag = outbound.tag
				sys.call(string.format("mkdir -p %s && touch %s/%s", api.TMP_IFACE_PATH, api.TMP_IFACE_PATH, node.iface))
			end
		else
			local outbound = gen_outbound(flag, node, nil, { fragment = xray_settings.fragment == "1" or nil, noise = xray_settings.fragment == "1" or nil })
			if outbound then
				outbound.tag = outbound.tag .. ":" .. node.remarks
				COMMON.default_outbound_tag, last_insert_outbound = set_outbound_detour(node, outbound, outbounds)
				table.insert(outbounds, outbound)
				if last_insert_outbound then
					table.insert(outbounds, last_insert_outbound)
				end
				routing = {
					domainStrategy = "AsIs",
					domainMatcher = "hybrid",
					rules = {}
				}
				table.insert(routing.rules, {
					ruleTag = "default",
					outboundTag = COMMON.default_outbound_tag,
					network = "tcp,udp"
				})
			end
		end
	end
	
	if dns_listen_port then
		local rules = {}
		local _remote_dns_proto = "tcp"
	
		if not routing then
			routing = {
				domainStrategy = "IPOnDemand",
				rules = {}
			}
		end
	
		dns = {
			tag = "dns-in1",
			hosts = {},
			disableCache = (dns_cache and dns_cache == "0") and true or false,
			disableFallback = true,
			disableFallbackIfMatch = true,
			servers = {},
			queryStrategy = "UseIP"
		}
	
		local dns_host = ""
		if flag == "global" then
			dns_host = uci:get(appname, "@global[0]", "dns_hosts") or ""
		else
			flag = flag:gsub("acl_", "")
			local dns_hosts_mode = uci:get(appname, flag, "dns_hosts_mode") or "default"
			if dns_hosts_mode == "default" then
				dns_host = uci:get(appname, "@global[0]", "dns_hosts") or ""
			elseif dns_hosts_mode == "disable" then
				dns_host = ""
			elseif dns_hosts_mode == "custom" then
				dns_host = uci:get(appname, flag, "dns_hosts") or ""
			end
		end
		if #dns_host > 0 then
			string.gsub(dns_host, '[^' .. "\r\n" .. ']+', function(w)
				local host = sys.exec(string.format("echo -n $(echo %s | awk -F ' ' '{print $1}')", w))
				local key = sys.exec(string.format("echo -n $(echo %s | awk -F ' ' '{print $2}')", w))
				if host ~= "" and key ~= "" then
					dns.hosts[host] = key
				end
			end)
		end

		local _remote_dns_ip = nil
	
		local _remote_dns = {
			_flag = "remote",
			queryStrategy = (remote_dns_query_strategy and remote_dns_query_strategy ~= "") and remote_dns_query_strategy or "UseIPv4"
		}

		if remote_dns_udp_server then
			_remote_dns.address = remote_dns_udp_server
			_remote_dns.port = tonumber(remote_dns_udp_port) or 53
			_remote_dns_proto = "udp"
			_remote_dns_ip = remote_dns_udp_server
		end

		if remote_dns_tcp_server then
			_remote_dns.address = "tcp://" .. remote_dns_tcp_server .. ":" .. tonumber(remote_dns_tcp_port) or 53
			_remote_dns.port = tonumber(remote_dns_tcp_port) or 53
			_remote_dns_proto = "tcp"
			_remote_dns_ip = remote_dns_tcp_server
		end

		if remote_dns_doh_url and remote_dns_doh_host then
			if remote_dns_doh_ip and remote_dns_doh_host ~= remote_dns_doh_ip and not api.is_ip(remote_dns_doh_host) then
				dns.hosts[remote_dns_doh_host] = remote_dns_doh_ip
			end
			_remote_dns.address = remote_dns_doh_url
			_remote_dns.port = tonumber(remote_dns_doh_port) or 443
			_remote_dns_ip = remote_dns_doh_ip
		end

		if _remote_dns.address then
			table.insert(dns.servers, _remote_dns)
			if remote_dns_detour == "direct" then
				table.insert(routing.rules, 1, {
					ip = {
						_remote_dns_ip
					},
					port = _remote_dns.port,
					network = _remote_dns_proto,
					outboundTag = "direct"
				})
			end
		end

		local _remote_fakedns = nil
		if remote_dns_fake then
			fakedns = {}
			local fakedns4 = {
				ipPool = "198.18.0.0/16",
				poolSize = 65535
			}
			local fakedns6 = {
				ipPool = "fc00::/18",
				poolSize = 65535
			}
			if remote_dns_query_strategy == "UseIP" then
				table.insert(fakedns, fakedns4)
				table.insert(fakedns, fakedns6)
			elseif remote_dns_query_strategy == "UseIPv4" then
				table.insert(fakedns, fakedns4)
			elseif remote_dns_query_strategy == "UseIPv6" then
				table.insert(fakedns, fakedns6)
			end
			_remote_fakedns = {
				_flag = "remote_fakedns",
				address = "fakedns",
			}
			table.insert(dns.servers, _remote_fakedns)
		end
	
		local _direct_dns = nil
		if direct_dns_udp_server then
			local domain = {}
			local nodes_domain_text = sys.exec('uci show passwall2 | grep ".address=" | cut -d "\'" -f 2 | grep "[a-zA-Z]$" | sort -u')
			string.gsub(nodes_domain_text, '[^' .. "\r\n" .. ']+', function(w)
				table.insert(domain, "full:" .. w)
			end)
			if #domain > 0 then
				table.insert(dns_domain_rules, 1, {
					outboundTag = "direct",
					domain = domain
				})
			end

			_direct_dns = {
				_flag = "direct",
				address = direct_dns_udp_server,
				port = tonumber(direct_dns_udp_port) or 53,
				queryStrategy = (direct_dns_query_strategy and direct_dns_query_strategy ~= "") and direct_dns_query_strategy or "UseIP",
			}
			table.insert(routing.rules, 1, {
				ip = {
					direct_dns_udp_server
				},
				port = tonumber(direct_dns_udp_port) or 53,
				network = "udp",
				outboundTag = "direct"
			})

			table.insert(dns.servers, _direct_dns)
		end
	
		if dns_listen_port then
			table.insert(inbounds, {
				listen = "127.0.0.1",
				port = tonumber(dns_listen_port),
				protocol = "dokodemo-door",
				tag = "dns-in",
				settings = {
					address = "0.0.0.0",
					network = "tcp,udp"
				}
			})
			local direct_type_dns = {
				settings = {
					address = direct_dns_udp_server,
					port = tonumber(direct_dns_udp_port) or 53,
					network = "udp",
					nonIPQuery = "skip",
					blockTypes = {
						65
					}
				},
				proxySettings = {
					tag = "direct"
				}
			}
			local remote_type_dns = {
				settings = {
					address = remote_dns_udp_server,
					port = tonumber(remote_dns_udp_port) or 53,
					network = _remote_dns_proto or "tcp",
					nonIPQuery = "drop"
				}
			}
			local type_dns = direct_type_dns
			table.insert(outbounds, {
				tag = "dns-out",
				protocol = "dns",
				proxySettings = type_dns.proxySettings,
				settings = type_dns.settings
			})
			table.insert(routing.rules, 1, {
				inboundTag = {
					"dns-in"
				},
				outboundTag = "dns-out"
			})
		end
	
		local default_dns_flag = "remote"
		if (not COMMON.default_balancer_tag and not COMMON.default_outbound_tag) or COMMON.default_outbound_tag == "direct" then
			default_dns_flag = "direct"
		end
	
		if dns.servers and #dns.servers > 0 then
			local dns_servers = nil
			for index, value in ipairs(dns.servers) do
				if not dns_servers and value["_flag"] == default_dns_flag then
					if value["_flag"] == "remote" and remote_dns_fake then
						value["_flag"] = "default"
						break
					end
					dns_servers = {
						_flag = "default",
						address = value.address,
						port = value.port,
						queryStrategy = value.queryStrategy
					}
					break
				end
			end
			if dns_servers then
				table.insert(dns.servers, 1, dns_servers)
			end

			--按分流顺序DNS
			if dns_domain_rules and #dns_domain_rules > 0 then
				for index, value in ipairs(dns_domain_rules) do
					if value.domain and (value.outboundTag or value.balancerTag) then
						local dns_server = nil
						if value.outboundTag == "direct" then
							dns_server = api.clone(_direct_dns)
						else
							if remote_dns_fake then
								dns_server = api.clone(_remote_fakedns)
							else
								dns_server = api.clone(_remote_dns)
							end
						end
						dns_server.domains = value.domain
						if value.shunt_rule_name then
							dns_server["_flag"] = value.shunt_rule_name
						end

						if dns_server then
							table.insert(dns.servers, dns_server)
						end
					end
				end
			end

			for i = #dns.servers, 1, -1 do
				local v = dns.servers[i]
				if v["_flag"] ~= "default" then
					if not v.domains or #v.domains == 0 then
						table.remove(dns.servers, i)
					end
				end
			end
		end
	
		local default_rule_index = #routing.rules > 0 and #routing.rules or 1
		for index, value in ipairs(routing.rules) do
			if value.ruleTag == "default" then
				default_rule_index = index
				break
			end
		end
		for index, value in ipairs(rules) do
			local t = rules[#rules + 1 - index]
			table.insert(routing.rules, default_rule_index, t)
		end
	
		local dns_hosts_len = 0
		for key, value in pairs(dns.hosts) do
			dns_hosts_len = dns_hosts_len + 1
		end
	
		if dns_hosts_len == 0 then
			dns.hosts = nil
		end

		local content = flag .. node_id .. jsonc.stringify(routing.rules)
		if api.cacheFileCompareToLogic(CACHE_TEXT_FILE, content) == false then
			--clear ipset/nftset
			if direct_ipset then
				string.gsub(direct_ipset, '[^' .. "," .. ']+', function(w)
					sys.call("ipset -q -F " .. w)
				end)
				local ipset_prefix_name = "passwall2_" .. node_id .. "_"
				local ipset_list = sys.exec("ipset list | grep 'Name: ' | grep '" .. ipset_prefix_name .. "' | awk '{print $2}'")
				string.gsub(ipset_list, '[^' .. "\r\n" .. ']+', function(w)
					sys.call("ipset -q -F " .. w)
				end)
			end
			if direct_nftset then
				string.gsub(direct_nftset, '[^' .. "," .. ']+', function(w)
					local split = api.split(w, "#")
					if #split > 3 then
						local ip_type = split[1]
						local family = split[2]
						local table_name = split[3]
						local set_name = split[4]
						sys.call(string.format("nft flush set %s %s %s 2>/dev/null", family, table_name, set_name))
					end
				end)
				local family = "inet"
				local table_name = "passwall2"
				local nftset_prefix_name = "passwall2_" .. node_id .. "_"
				local nftset_list = sys.exec("nft -a list sets | grep -E '" .. nftset_prefix_name .. "' | awk -F 'set ' '{print $2}' | awk '{print $1}'")
				string.gsub(nftset_list, '[^' .. "\r\n" .. ']+', function(w)
					sys.call(string.format("nft flush set %s %s %s 2>/dev/null", family, table_name, w))
				end)
			end
		end
	end
	
	if inbounds or outbounds then
		local config = {
			log = {
				--access = string.format("/tmp/etc/%s/%s_access.log", appname, "global"),
				--error = string.format("/tmp/etc/%s/%s_error.log", appname, "global"),
				--dnsLog = true,
				loglevel = loglevel
			},
			-- DNS
			dns = dns,
			fakedns = fakedns,
			-- 传入连接
			inbounds = inbounds,
			-- 传出连接
			outbounds = outbounds,
			-- 连接观测
			observatory = observatory,
			-- 路由
			routing = routing,
			-- 本地策略
			policy = {
				levels = {
					[0] = {
						-- handshake = 4,
						-- connIdle = 300,
						-- uplinkOnly = 2,
						-- downlinkOnly = 5,
						bufferSize = xray_settings.buffer_size and tonumber(xray_settings.buffer_size) or nil,
						statsUserUplink = false,
						statsUserDownlink = false
					}
				},
				-- system = {
				--     statsInboundUplink = false,
				--     statsInboundDownlink = false
				-- }
			}
		}

		if xray_settings.fragment == "1" or xray_settings.noise == "1" then
			table.insert(outbounds, {
				protocol = "freedom",
				tag = "dialerproxy",
				settings = {
					domainStrategy = (direct_dns_query_strategy and direct_dns_query_strategy ~= "") and direct_dns_query_strategy or "UseIP",
					fragment = (xray_settings.fragment == "1") and {
						packets = (xray_settings.fragment_packets and xray_settings.fragment_packets ~= "") and xray_settings.fragment_packets,
						length = (xray_settings.fragment_length and xray_settings.fragment_length ~= "") and xray_settings.fragment_length,
						interval = (xray_settings.fragment_interval and xray_settings.fragment_interval ~= "") and xray_settings.fragment_interval
					} or nil,
					noises = (xray_settings.noise == "1") and get_noise_packets() or nil
				},
				streamSettings = {
					sockopt = {
						mark = 255,
						tcpNoDelay = true
					}
				}
			})
		end

		local direct_outbound = {
			protocol = "freedom",
			tag = "direct",
			settings = {
				domainStrategy = (direct_dns_query_strategy and direct_dns_query_strategy ~= "") and direct_dns_query_strategy or "UseIP"
			},
			streamSettings = {
				sockopt = {
					mark = 255
				}
			}
		}
		if COMMON.default_outbound_tag == "direct" then
			table.insert(outbounds, 1, direct_outbound)
		else
			table.insert(outbounds, direct_outbound)
		end

		local blackhole_outbound = {
			protocol = "blackhole",
			tag = "blackhole"
		}
		if COMMON.default_outbound_tag == "blackhole" then
			table.insert(outbounds, 1, blackhole_outbound)
		else
			table.insert(outbounds, blackhole_outbound)
		end

		for index, value in ipairs(config.outbounds) do
			if not value["_flag_proxy_tag"] and value["_id"] and value.server and value.server_port then
				sys.call(string.format("echo '%s' >> %s", value["_id"], api.TMP_PATH .. "/direct_node_list"))
			end
			for k, v in pairs(config.outbounds[index]) do
				if k:find("_") == 1 then
					config.outbounds[index][k] = nil
				end
			end
		end
		return jsonc.stringify(config, 1)
	end
end

function gen_proto_config(var)
	local local_socks_address = var["-local_socks_address"] or "0.0.0.0"
	local local_socks_port = var["-local_socks_port"]
	local local_socks_username = var["-local_socks_username"]
	local local_socks_password = var["-local_socks_password"]
	local local_http_address = var["-local_http_address"] or "0.0.0.0"
	local local_http_port = var["-local_http_port"]
	local local_http_username = var["-local_http_username"]
	local local_http_password = var["-local_http_password"]
	local server_proto = var["-server_proto"]
	local server_address = var["-server_address"]
	local server_port = var["-server_port"]
	local server_username = var["-server_username"]
	local server_password = var["-server_password"]
	
	local inbounds = {}
	local outbounds = {}
	local routing = nil

	if local_socks_address and local_socks_port then
		local inbound = {
			listen = local_socks_address,
			port = tonumber(local_socks_port),
			protocol = "socks",
			settings = {
				udp = true,
				auth = "noauth"
			}
		}
		if local_socks_username and local_socks_password and local_socks_username ~= "" and local_socks_password ~= "" then
			inbound.settings.auth = "password"
			inbound.settings.accounts = {
				{
					user = local_socks_username,
					pass = local_socks_password
				}
			}
		end
		table.insert(inbounds, inbound)
	end
	
	if local_http_address and local_http_port then
		local inbound = {
			listen = local_http_address,
			port = tonumber(local_http_port),
			protocol = "http",
			settings = {
				allowTransparent = false
			}
		}
		if local_http_username and local_http_password and local_http_username ~= "" and local_http_password ~= "" then
			inbound.settings.accounts = {
				{
					user = local_http_username,
					pass = local_http_password
				}
			}
		end
		table.insert(inbounds, inbound)
	end
	
	if server_proto ~= "nil" and server_address ~= "nil" and server_port ~= "nil" then
		local outbound = {
			protocol = server_proto,
			streamSettings = {
				network = "tcp",
				security = "none"
			},
			settings = {
				servers = {
					{
						address = server_address,
						port = tonumber(server_port),
						users = (server_username and server_password) and {
							{
								user = server_username,
								pass = server_password
							}
						} or nil
					}
				}
			}
		}
		if outbound then table.insert(outbounds, outbound) end
	end
	
	-- 额外传出连接
	table.insert(outbounds, {
		protocol = "freedom", tag = "direct", settings = {keep = ""}
	})
	
	local config = {
		log = {
			loglevel = "warning"
		},
		-- 传入连接
		inbounds = inbounds,
		-- 传出连接
		outbounds = outbounds,
		-- 路由
		routing = routing
	}
	return jsonc.stringify(config, 1)
end

function gen_dns_config(var)
	local dns_listen_port = var["-dns_listen_port"]
	local dns_out_tag = var["-dns_out_tag"]
	local direct_dns_udp_server = var["-direct_dns_udp_server"]
	local direct_dns_udp_port = var["-direct_dns_udp_port"]
	local direct_dns_tcp_server = var["-direct_dns_tcp_server"]
	local direct_dns_tcp_port = var["-direct_dns_tcp_port"]
	local direct_dns_doh_url = var["-direct_dns_doh_url"]
	local direct_dns_doh_host = var["-direct_dns_doh_host"]
	local direct_dns_doh_ip = var["-direct_dns_doh_ip"]
	local direct_dns_doh_port = var["-direct_dns_doh_port"]
	local direct_dns_query_strategy = var["-direct_dns_query_strategy"]
	local remote_dns_udp_server = var["-remote_dns_udp_server"]
	local remote_dns_udp_port = var["-remote_dns_udp_port"]
	local remote_dns_tcp_server = var["-remote_dns_tcp_server"]
	local remote_dns_tcp_port = var["-remote_dns_tcp_port"]
	local remote_dns_doh_url = var["-remote_dns_doh_url"]
	local remote_dns_doh_host = var["-remote_dns_doh_host"]
	local remote_dns_doh_ip = var["-remote_dns_doh_ip"]
	local remote_dns_doh_port = var["-remote_dns_doh_port"]
	local remote_dns_query_strategy = var["-remote_dns_query_strategy"]
	local remote_dns_detour = var["-remote_dns_detour"]
	local remote_dns_client_ip = var["-remote_dns_client_ip"]
	local remote_dns_outbound_socks_address = var["-remote_dns_outbound_socks_address"]
	local remote_dns_outbound_socks_port = var["-remote_dns_outbound_socks_port"]
	local dns_cache = var["-dns_cache"]
	local loglevel = var["-loglevel"] or "warning"
	
	local inbounds = {}
	local outbounds = {}
	local dns = nil
	local routing = nil

	if dns_listen_port then
		routing = {
			domainStrategy = "IPOnDemand",
			rules = {}
		}
	
		dns = {
			tag = "dns-in1",
			hosts = {},
			disableCache = (dns_cache == "1") and false or true,
			disableFallback = true,
			disableFallbackIfMatch = true,
			servers = {},
			clientIp = (remote_dns_client_ip and remote_dns_client_ip ~= "") and remote_dns_client_ip or nil,
		}
	
		local other_type_dns_proto, other_type_dns_server, other_type_dns_port
	
		if dns_out_tag == "remote" then
			dns.queryStrategy = (remote_dns_query_strategy and remote_dns_query_strategy ~= "") and remote_dns_query_strategy or "UseIPv4"
			if remote_dns_detour == "direct" then
				dns_out_tag = "direct"
				table.insert(outbounds, 1, {
					tag = dns_out_tag,
					protocol = "freedom",
					settings = {
						domainStrategy = (direct_dns_query_strategy and direct_dns_query_strategy ~= "") and direct_dns_query_strategy or "UseIP"
					},
					streamSettings = {
						sockopt = {
							mark = 255
						}
					}
				})
			else
				if remote_dns_outbound_socks_address and remote_dns_outbound_socks_port then
					table.insert(outbounds, 1, {
						tag = dns_out_tag,
						protocol = "socks",
						streamSettings = {
							network = "tcp",
							security = "none"
						},
						settings = {
							servers = {
								{
									address = remote_dns_outbound_socks_address,
									port = tonumber(remote_dns_outbound_socks_port)
								}
							}
						}
					})
				end
			end

			local _remote_dns = {
				_flag = "remote"
			}
	
			if remote_dns_udp_server then
				_remote_dns.address = remote_dns_udp_server
				_remote_dns.port = tonumber(remote_dns_udp_port) or 53
				
				other_type_dns_proto = "udp"
				other_type_dns_server = remote_dns_udp_server
				other_type_dns_port = _remote_dns.port
			end
	
			if remote_dns_tcp_server then
				_remote_dns.address = "tcp://" .. remote_dns_tcp_server .. ":" .. tonumber(remote_dns_tcp_port) or 53
				_remote_dns.port = tonumber(remote_dns_tcp_port) or 53
				
				other_type_dns_proto = "tcp"
				other_type_dns_server = remote_dns_tcp_server
				other_type_dns_port = _remote_dns.port
			end
	
			if remote_dns_doh_url and remote_dns_doh_host then
				if remote_dns_doh_ip and remote_dns_doh_host ~= remote_dns_doh_ip and not api.is_ip(remote_dns_doh_host) then
					dns.hosts[remote_dns_doh_host] = remote_dns_doh_ip
				end
				_remote_dns.address = remote_dns_doh_url
				_remote_dns.port = tonumber(remote_dns_doh_port) or 443
			end
	
			table.insert(dns.servers, _remote_dns)
		elseif dns_out_tag == "direct" then
			dns.queryStrategy = (direct_dns_query_strategy and direct_dns_query_strategy ~= "") and direct_dns_query_strategy or "UseIP"
			table.insert(outbounds, 1, {
				tag = dns_out_tag,
				protocol = "freedom",
				settings = {
					domainStrategy = dns.queryStrategy
				},
				streamSettings = {
					sockopt = {
						mark = 255
					}
				}
			})

			local _direct_dns = {
				_flag = "direct"
			}
	
			if direct_dns_udp_server then
				_direct_dns.address = direct_dns_udp_server
				_direct_dns.port = tonumber(direct_dns_udp_port) or 53
				table.insert(routing.rules, 1, {
					ip = {
						direct_dns_udp_server
					},
					port = tonumber(direct_dns_udp_port) or 53,
					network = "udp",
					outboundTag = "direct"
				})

				other_type_dns_proto = "udp"
				other_type_dns_server = direct_dns_udp_server
				other_type_dns_port = _direct_dns.port
			end
	
			if direct_dns_tcp_server then
				_direct_dns.address = "tcp+local://" .. direct_dns_tcp_server
				_direct_dns.port = tonumber(direct_dns_tcp_port) or 53
				
				other_type_dns_proto = "tcp"
				other_type_dns_server = direct_dns_tcp_server
				other_type_dns_port = _direct_dns.port
			end
	
			if direct_dns_doh_url and direct_dns_doh_host then
				if direct_dns_doh_ip and direct_dns_doh_host ~= direct_dns_doh_ip and not api.is_ip(direct_dns_doh_host) then
					dns.hosts[direct_dns_doh_host] = direct_dns_doh_ip
				end
				_direct_dns.address = direct_dns_doh_url:gsub("https://", "https+local://")
				_direct_dns.port = tonumber(direct_dns_doh_port) or 443
			end
	
			table.insert(dns.servers, _direct_dns)
		end
	
		local dns_hosts_len = 0
		for key, value in pairs(dns.hosts) do
			dns_hosts_len = dns_hosts_len + 1
		end
	
		if dns_hosts_len == 0 then
			dns.hosts = nil
		end
	
		table.insert(inbounds, {
			listen = "127.0.0.1",
			port = tonumber(dns_listen_port),
			protocol = "dokodemo-door",
			tag = "dns-in",
			settings = {
				address = other_type_dns_server or "1.1.1.1",
				port = other_type_dns_port or 53,
				network = "tcp,udp"
			}
		})
	
		table.insert(outbounds, {
			tag = "dns-out",
			protocol = "dns",
			proxySettings = {
				tag = dns_out_tag
			},
			settings = {
				address = other_type_dns_server or "1.1.1.1",
				port = other_type_dns_port or 53,
				network = other_type_dns_proto or "tcp",
				nonIPQuery = "drop"
			}
		})
	
		table.insert(routing.rules, 1, {
			inboundTag = {
				"dns-in"
			},
			outboundTag = "dns-out"
		})
	
		table.insert(routing.rules, {
			inboundTag = {
				"dns-in1"
			},
			outboundTag = dns_out_tag
		})
	end
	
	if inbounds or outbounds then
		local config = {
			log = {
				--dnsLog = true,
				loglevel = loglevel
			},
			-- DNS
			dns = dns,
			-- 传入连接
			inbounds = inbounds,
			-- 传出连接
			outbounds = outbounds,
			-- 路由
			routing = routing
		}
		return jsonc.stringify(config, 1)
	end
	
end

_G.gen_config = gen_config
_G.gen_proto_config = gen_proto_config
_G.gen_dns_config = gen_dns_config

if arg[1] then
	local func =_G[arg[1]]
	if func then
		print(func(api.get_function_args(arg)))
	end
end