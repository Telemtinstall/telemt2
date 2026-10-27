"""HY2-specific delivery; AWG/VLESS Actions and their generators stay unchanged."""
from app.actions import Actions
from app import formatters, keyboards

class HysteriaActions(Actions):
    def endpoint_apply(self,chat_id,kind,domain,ip):
        from app.ip_admin import switch_command
        if any(s.protocol=='hysteria2' for s in self.servers.servers):
            raise RuntimeError('Смена IP/домена Hysteria требует согласования сертификата; в этой сборке запрещена')
        result = switch_command('apply',ip,registry=self.settings.servers_path) if kind=='ip' else switch_command('domain-set',domain,'--address',ip,registry=self.settings.servers_path)
        self.telegram.send_message(chat_id,'Настройки VPN сохранены. Получите новые профили. A-запись домена измените у регистратора самостоятельно.')
    def menu_stats(self):
        # Navigation is served without waiting for protocol CLIs.
        return None
    def create_client(self,chat_id,server_id,name=None):
        server=self.servers.get(server_id)
        if server.protocol!='hysteria2':return super().create_client(chat_id,server_id,name)
        self.require_protocol_enabled(server_id)
        data=server.add(name)
        verified=server.show(data['name'])
        if verified.get('uuid')!=data.get('uuid'):raise RuntimeError('HY2 profile verification failed')
        if self.traffic_store:self.traffic_store.ensure_user(server.id,server.protocol,data['name'])
        self.telegram.send_message(chat_id,'Пользователь '+formatters.h(data['name'])+' создан.',keyboards.client_actions(server.id,server.protocol,data['name']))
        return data['name']
    @staticmethod
    def qr_delivery_details(server,platform):
        if getattr(server,'protocol','')=='hysteria2':return ('QR Hysteria 2','Клиент с поддержкой выбранной обфускации Hysteria 2','Импортируйте QR в приложении. Поддержку Gecko проверьте по версии клиента.')
        return Actions.qr_delivery_details(server,platform)
    def send_vless_link_for_client(self,chat_id,server_id,ref):
        server=self.servers.get(server_id)
        if server.protocol!='hysteria2':return super().send_vless_link_for_client(chat_id,server_id,ref)
        self.require_protocol_enabled(server_id)
        data=server.show(ref);self.verify_profile(ref,data,server_id)
        self.telegram.send_message(chat_id,'<b>Hysteria 2</b>\n<code>'+formatters.h(data['link'])+'</code>')
    def send_config_file_for_client(self,chat_id,server_id,ref):
        server=self.servers.get(server_id)
        if server.protocol!='hysteria2':return super().send_config_file_for_client(chat_id,server_id,ref)
        self.require_protocol_enabled(server_id)
        data=server.show(ref);self.verify_profile(ref,data,server_id)
        self.telegram.send_document(chat_id,ref+'.yaml',data['clash_yaml'].encode(),'Hysteria 2 · YAML для Clash','application/yaml')
    def apply_list_statuses(self,server,clients):
        if server.protocol!='hysteria2':return super().apply_list_statuses(server,clients)
        statuses={c['name']:c for c in server.online().get('clients',[])}
        return [dict(c, status=statuses.get(c['name'],{}).get('status','offline')) for c in clients]
    def show_online(self,chat_id,server_id,message_id=None):
        server=self.servers.get(server_id)
        if server.protocol!='hysteria2':return super().show_online(chat_id,server_id,message_id)
        clients=server.online().get('clients',[])
        names=[formatters.h(c['name']) for c in clients if c.get('online')]
        self.telegram.send_message(chat_id,'<b>Hysteria 2 · онлайн</b>\n'+('\n'.join(names) or 'Нет активных подключений.'))
    def show_all_online(self,chat_id):
        if not any(s.protocol=='hysteria2' for s in self.enabled_servers()):return super().show_all_online(chat_id)
        for server in self.enabled_servers():self.show_online(chat_id,server.id)
