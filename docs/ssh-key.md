# Chave SSH: uma só, para sempre

O VS Code (Windows) e os comandos `make` (WSL) são dois "computadores"
diferentes, cada um com a sua pasta `.ssh`:

| Onde | Pasta | Quem usa |
|---|---|---|
| Windows | `C:\Users\<você>\.ssh\` (no WSL: `/mnt/c/Users/<você>/.ssh/`) | VS Code Remote - SSH, `ssh cdw`, `cdw-push` |
| WSL | `~/.ssh/` (ex.: `/home/<usuário>/.ssh/`) | `make up`, `make connect`, `make push`... |

O `make up` registra na Hetzner (chave `cdw-operator`) e coloca na VM **só** a
chave do `.env` (`CDW_SSH_PUBLIC_KEY_FILE`, por padrão `~/.ssh/id_ed25519.pub`
**do WSL**). Se o Windows tiver outra chave, o VS Code recebe
`Permission denied (publickey)`, mesmo com o `make connect` funcionando.
Um `IdentityFile /home/...` no `config` do Windows também não funciona: esse
caminho só existe dentro do WSL.

Só arquivos `.pub` (públicos) são copiados ou mostrados nestes passos. A chave
privada (sem `.pub`) nunca sai do seu computador e nunca deve ser colada em
chat, ticket ou console web.

## 1. Descobrir qual chave a VM aceita
Compare as impressões digitais MD5 (é o formato que o console da Hetzner
mostra em **Security > SSH keys**, na chave `cdw-operator`):

```bash
# WSL
ssh-keygen -l -E md5 -f ~/.ssh/id_ed25519.pub
```
```powershell
# PowerShell
ssh-keygen -l -E md5 -f $env:USERPROFILE\.ssh\id_ed25519.pub
```
Ou rode `make key-check` no WSL: ele mostra a chave do `.env`, a do Windows,
a registrada na Hetzner e testa a entrada na VM atual.

- A do **WSL** bate com a da Hetzner: siga o passo 2 (Caminho A), leva 1 minuto.
- **Nenhuma** bate (a VM foi criada de outro computador ou de uma chave que
  você não tem mais): siga o passo 3 (Caminho B).

## 2. Caminho A: autorizar a chave do Windows pela chave do WSL
No WSL, na pasta do repositório:
```bash
make authorize-key        # sem CHAVE, usa /mnt/c/Users/<você>/.ssh/id_ed25519.pub
# ou: make authorize-key CHAVE=/mnt/c/Users/<você>/.ssh/id_ed25519.pub
make key-check            # deve terminar com "tudo certo"
```
O `make authorize-key` entra na VM com a chave que já funciona e acrescenta a
`.pub` do Windows em `/home/dev/.ssh/authorized_keys` (sem duplicar se rodar
de novo). Não recria nada e não reinicia a VM.

No Windows, confira o bloco `Host cdw` em `C:\Users\<você>\.ssh\config`:
```
Host cdw
    HostName <IP atual>
    User dev
    IdentityFile ~/.ssh/id_ed25519
    IdentitiesOnly yes
```
(`~` no Windows é `C:\Users\<você>`; troque qualquer `IdentityFile /home/...`.)
Depois: `ssh cdw` no PowerShell e o VS Code voltam a entrar.

Isso vale só para esta VM. Para a próxima já nascer certa, faça o passo 4.

## 3. Caminho B: a VM não aceita nenhuma chave minha
Use o **modo rescue** da Hetzner (recomendado: copiar e colar funciona,
porque você usa um terminal SSH normal). Os dados no disco da VM não são
apagados, mas a VM **reinicia duas vezes**: salve o trabalho e saiba que
sessões abertas e contêineres caem (os que têm `restart: unless-stopped`
voltam sozinhos).

1. No console da Hetzner, **Security > SSH keys > Add SSH key**: cole o
   conteúdo do seu `C:\Users\<você>\.ssh\id_ed25519.pub` (a linha que começa
   com `ssh-ed25519`). Dê um nome como `windows-temporaria`. **Não** use o
   nome `cdw-operator` (esse é gerenciado pelo OpenTofu).
2. Em **Servers > cdw > Rescue**, clique em **Enable rescue & power cycle**,
   escolha `linux64` e marque a chave `windows-temporaria`. A VM reinicia no
   sistema de resgate (vale só para esta inicialização).
3. No PowerShell (o rescue tem outra chave de host; por isso um `known_hosts`
   separado, que você apaga no fim):
   ```powershell
   ssh -o UserKnownHostsFile=$env:TEMP\cdw-rescue-hosts -o StrictHostKeyChecking=accept-new root@<IP da VM>
   ```
4. Dentro do rescue:
   ```bash
   lsblk                                   # o disco da VM é sda; a raiz costuma ser sda1 (a maior partição)
   mount /dev/sda1 /mnt
   ls /mnt/home/dev/.ssh/authorized_keys   # confere que é o disco certo
   cat >> /mnt/home/dev/.ssh/authorized_keys
   ```
   Cole a linha do seu `.pub` do Windows, aperte Enter e depois **Ctrl+D**. Então:
   ```bash
   tail -n 2 /mnt/home/dev/.ssh/authorized_keys      # a sua linha deve aparecer inteira
   chroot /mnt chown dev:dev /home/dev/.ssh/authorized_keys
   chmod 600 /mnt/home/dev/.ssh/authorized_keys
   umount /mnt
   reboot
   ```
5. Espere 1 a 2 minutos e rode `ssh cdw` no PowerShell. Apague
   `$env:TEMP\cdw-rescue-hosts`.
6. **Apague a chave `windows-temporaria` em Security > SSH keys.** A Hetzner não
   aceita a mesma chave pública registrada duas vezes; se ela ficar lá, o
   próximo `make up` falha ao registrar a `cdw-operator` com essa chave.

Ressalvas:
- A porta 22 só abre para o IP liberado no `make up`. Se o `ssh` der *timeout*
  (e não *Permission denied*), o seu IP mudou; libere-o no firewall `cdw-fw`
  do console antes.
- Alternativa sem reinício: **Rescue > Reset root password** + botão de
  console (`>_`) e login como `root`. Funciona, mas no console web você
  precisa **digitar** a chave inteira (cerca de 80 caracteres sem erro). Se
  a sua chave do Windows estiver no GitHub, dá para buscar de lá:
  `curl -fsS https://github.com/<seu-login>.keys` (confira qual linha é a do
  Windows antes de acrescentá-la). Ao terminar, rode `passwd -l root` para
  travar de novo a senha do root (o SSH já recusa root de qualquer forma).
- Se não quiser nenhuma dessas, `make down` + `make up` cria uma VM nova já
  com a chave do `.env` (o backup restaura os dados); depois do passo 4.

## 4. Chave SSH definitiva (a mesma no Windows, no WSL e em toda VM)
Escolha **a chave do Windows** como a única, porque é a que o VS Code usa.
Faça isto **depois** de a VM atual aceitar a chave do Windows (passo 2 ou 3),
senão o `make connect` perde o acesso a ela.

No WSL (troque `<você>` pelo seu usuário do Windows):
```bash
install -d -m 700 ~/.ssh
install -m 600 /mnt/c/Users/<você>/.ssh/id_ed25519     ~/.ssh/cdw_ed25519
install -m 644 /mnt/c/Users/<você>/.ssh/id_ed25519.pub ~/.ssh/cdw_ed25519.pub
```
A cópia fica no WSL porque o `ssh` recusa uma chave privada em `/mnt/c` (lá
as permissões aparecem como abertas). É a mesma chave; nada novo é criado.

No `.env`:
```
CDW_SSH_PUBLIC_KEY_FILE=~/.ssh/cdw_ed25519.pub
# CDW_SSH_PRIVATE_KEY_FILE=~/.ssh/cdw_ed25519   (padrão: o mesmo caminho sem .pub)
```
Confira com `make key-check`: as linhas do Windows e da VM devem dar `[ok]`.
O `make init` também avisa se o Windows passar a usar outra chave.

A partir daí:
- Toda VM nova (`make up`) já nasce aceitando essa chave, e o VS Code entra
  sem nenhum passo extra. O `make connect-print` mostra o `IdentityFile` com
  o caminho do Windows (nunca `/home/...`), e o `cdw-push -ConfigOnly` só
  troca o IP.
- Enquanto a VM atual existir, a Hetzner ainda mostra a chave antiga em
  `cdw-operator`. Isso não atrapalha. Se rodar `make plan`/`make up` com essa
  VM viva, o plano para com um aviso de troca de chave; como você já
  autorizou a nova, rode com `CDW_ALLOW_KEY_ROTATION=1 make up` (atualiza só o
  registro; a VM não é recriada).
- Se um dia precisar trocar a chave: com a antiga ainda no `.env`, rode
  `make authorize-key CHAVE=<nova>.pub`, troque o `.env` e siga como acima.
- Guarde uma cópia da chave privada no seu gerenciador de senhas. Se perder
  a chave do Windows, o caminho é o passo 3 (ou uma VM nova).
