"""Admin-only v3 menus; all CLI calls are dispatched by the durable worker."""
import json
import subprocess
from app import keyboards, formatters
from app.servers import ControllerError

TITLES={'awg31':'AmneziaWG 3.1','hy2':'Hysteria 2'}
CHOICES={'both-off':'Оба новых параметра: выкл','both-on':'Включить оба',
 'trailers-on':'RandomTrailers: включить','trailers-off':'RandomTrailers: выключить',
 'cookies-on':'DisableCookies: включить','cookies-off':'DisableCookies: выключить',
 'none':'Без обфускации (QUIC)','salamander':'Salamander','gecko':'Gecko · экспериментальный',
 'rollback':'Вернуть предыдущие настройки'}
WARNING=('Изменение затронет всех пользователей этого протокола. '
 'Соединения могут прерваться. После применения получите новые профили или QR '
 'и импортируйте их на устройствах. Старые скачанные профили сами не обновятся. '
 'Ключи пользователей и порты сохраняются.')

class ObfuscationActions:
    def obfs_command(self, protocol, *args):
        ids={'awg31':'amneziawg3','hy2':'hysteria2'}
        if protocol not in ids: raise ControllerError('Неизвестный протокол',unchanged=True)
        server=self.servers.get(ids[protocol])
        if server.config.transport!='local': raise ControllerError('Обфускация доступна только локальному протоколу',unchanged=True)
        p=subprocess.run(['/usr/local/sbin/vpnbot-obfuscation',*args[:1],protocol,*args[1:]],capture_output=True,text=True,timeout=100)
        try: result=json.loads(p.stdout)
        except ValueError: raise ControllerError('Контроллер обфускации не ответил') from None
        if p.returncode or not result.get('ok'):
            raise ControllerError(result.get('error','Ошибка обфускации'),unchanged=result.get('changed') is False)
        return result
    def show_obfuscation(self,chat_id,protocol=''):
        if not protocol:
            present={s.id for s in self.servers.servers if s.config.transport=='local'}
            rows=[[{'text':title,'callback_data':'obfs:'+key}] for key,title in TITLES.items()
                  if {'awg31':'amneziawg3','hy2':'hysteria2'}[key] in present]
            self.telegram.send_message(chat_id,'<b>Обфускация</b>\nВыберите протокол. Настройки относятся ко всем его пользователям.',keyboards.browsing([]))
        else:
            try: data=self.obfs_command(protocol,'status')
            except ControllerError as exc:
                self.telegram.send_message(chat_id,formatters.h(exc),keyboards.browsing([]));return
            title=TITLES[protocol];current=data['current'];rev=data['revision']
            text='\n'.join(f'{k}: {v}' for k,v in current.items())
            choices=data['choices']
            if protocol=='awg31':
                choices=['both-on','trailers-'+('off' if current['RandomTrailers']=='on' else 'on'),
                         'cookies-'+('off' if current['DisableCookies']=='on' else 'on')]
            if protocol!='awg31' and data.get('rollback'): choices=choices+['rollback']
            rows=[[{'text':CHOICES[c],'callback_data':f'obfsask:{protocol}:{c}:{rev}'}] for c in choices]
            self.telegram.send_message(chat_id,'<b>'+title+'</b>\n'+formatters.h(text)+'\n\n'+
                ('Можно включить оба параметра сразу или переключать каждый отдельно. Изменения относятся ко всем пользователям AWG 3.1.' if protocol=='awg31' else 'Gecko требует совместимого клиента. Обфускация заменяет обычное поведение QUIC.'),keyboards.browsing([]))
        rows.append([{'text':keyboards.BACK,'callback_data':'obfsback'},{'text':keyboards.MAIN_MENU,'callback_data':'menu'}])
        self.telegram.send_message(chat_id,'Выберите действие:',{'inline_keyboard':rows})
    def ask_obfuscation(self,chat_id,protocol,choice,revision):
        if protocol not in TITLES or choice not in CHOICES: raise ControllerError('Неверный режим',unchanged=True)
        self.telegram.send_message(chat_id,'<b>'+TITLES[protocol]+'</b>\n'+CHOICES[choice]+'\n\n'+WARNING,keyboards.operation_navigation())
        self.telegram.send_message(chat_id,'Применить настройки?',{'inline_keyboard':[[
            {'text':'Применить','callback_data':f'obfsapply:{protocol}:{choice}:{revision}'},
            {'text':'Отмена','callback_data':'obfscancel:'+protocol}]]})
    def apply_obfuscation(self,chat_id,protocol,choice,revision):
        result=self.obfs_command(protocol,'apply',choice,revision)
        self.telegram.send_message(chat_id,'Настройки обфускации применены. Резервная копия сохранена.\nПолучите новые профили/QR для устройств.',keyboards.browsing([]))
        self.show_obfuscation(chat_id,protocol)
