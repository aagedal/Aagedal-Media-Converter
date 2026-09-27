# Aagedal Media Converter

[English](../../README.md) · [Norsk bokmål](README.nb.md) · [Español](README.es.md) · [简体中文](README.zh-CN.md) · [Français](README.fr.md) · [Italiano](README.it.md) · [Deutsch](README.de.md) · [日本語](README.ja.md) · [Português (Brasil)](README.pt-BR.md) · [한국어](README.ko.md)

<img alt="Aagedal Media Converter" src="https://github.com/user-attachments/assets/213e64a6-f382-4562-b4cf-797ad1e0f368" />

Um aplicativo leve e minimalista para macOS, simples à primeira vista, mas com recursos poderosos. Usa FFmpeg, MPV, SwiftMediaMetadata, yt-dlp, rclone e whisper.cpp, e é escrito inteiramente em Swift / SwiftUI.

Totalmente gratuito e de código aberto. Privado e local. A verificação opcional de atualizações vem ativada por padrão, mas pode ser desativada.

Um projeto pessoal feito por paixão: criei o app para trabalhar com mais eficiência e quis compartilhá-lo. Grande parte do aplicativo foi desenvolvida por meio de “vibe coding”, com assistência de IA.

---

## Instalação

### Homebrew
```bash
brew tap aagedal/tap && brew install --cask aagedal-media-converter
```

### Download manual
[Baixe a versão atual](https://github.com/aagedal/Aagedal-Media-Converter/releases/latest)

---

## Principais recursos

- **Inicialização rápida e uso simples**
- **Conversão em lote** de quase todos os arquivos de vídeo e áudio (alternativa ao Shutter Encoder ou Handbrake)
- **Reprodução** em tela cheia com timecode e controles JKL (alternativa ao IINA ou VLC)
- **Visualização e comparação de metadados**, incluindo detecção de C2PA (alternativa ao MediaInfo)
- **Download** de vídeos de sites, com agendamento e download de transmissões ao vivo
- **Gravação de tela** com áudio do sistema e trilha de microfone separada opcional (alternativa ao OBS)
- **Transcrição** de vídeo e áudio para legendas SRT
- **Upload** para um servidor após a conversão

- **Unir** clipes em uma timeline com prévia da sequência e corte com ripple
- **Automatizar conversões por MCP local** com acesso de agentes ativado opcionalmente

### Geral

- Pré-visualização e codificação de quase todos os arquivos de vídeo
- Importação e exportação de **sequências de imagens** (PNG, TIFF, EXR, DPX, JPEG 2000 e outras) com áudio associado e controle da taxa de quadros
- Exportação de **DCP (Digital Cinema Package)** com imagem JPEG 2000 XYZ e áudio PCM
- Exportação experimental de pacotes **IMF App 2e e RDD 45** para validação na ferramenta de entrega
- Conversão em lote, pasta monitorada e barra de progresso
- Corte de duração, recorte de imagem, remapeamento ou remoção de trilhas de áudio e união de clipes do mesmo formato
- Visualização e comparação de metadados
- Muitos [atalhos de teclado](../../KeyboardShortcuts.md): a maioria dos recursos pode ser usada sem mouse
- Diversas configurações de personalização
- Verificação automática de atualizações com notificação discreta, que pode ser desativada
- Download do YouTube, TikTok etc. (yt-dlp)
- Transcrição para SRT (whisper.cpp)
- Upload por FTP (rclone)
- Verificação de assinatura C2PA (SwiftMediaMetadata)
- Gravação de tela em HDR com áudio do sistema e microfone opcional em uma trilha separada

### Conversão em lote

- Codifica automaticamente todos os arquivos da fila
- Altera a ordem de codificação arrastando e soltando arquivos
- Remove arquivos da fila durante a codificação

### Pasta monitorada

- Importa automaticamente os arquivos de uma pasta específica
- Funciona junto com a importação manual por arrastar e soltar, reunindo todas as conversões em uma janela
- Opções para excluir automaticamente e ignorar arquivos da pasta
- Ativação pelo ícone de olho na barra de ferramentas da janela principal

### Pré-visualização

- Atalhos comuns de edição, como JKL e as setas
- Medidor simples de nível de áudio (⌘A)
- Player nativo do macOS para arquivos compatíveis, com reprodução fluida até de trás para frente
- Alternância automática para MPVKit em arquivos não suportados nativamente pelo macOS, embora a reprodução reversa seja menos confiável

### Ajustes rápidos

- Corte de duração pelas alças ou pelas teclas I/O
- Cópia do timecode da origem, definição manual ou remoção
- Recorte da imagem com controles na tela; pressione C ou o ícone de recorte na visualização de corte de duração
    - Não funciona com o preset Stream Copy
- Exclusão ou reorganização das trilhas de áudio
    - Não funciona com o preset Stream Copy

### Unir arquivos da fila

- Une arquivos com os mesmos codec, resolução, taxa de quadros, profundidade de bits e trilhas de áudio
- O primeiro clipe determina o timecode e o recorte da imagem
- Edite grupos na timeline com tiras de miniaturas, reprodução da sequência, corte com ripple, reordenação, divisão, exclusão de intervalos e desfazer.
- Corte e una com Stream Copy sem recodificar. Os cortes dependem dos quadros-chave da origem e podem diferir dos limites selecionados; alguns metadados podem ser perdidos.
- Exporte marcadores de clipes em EDL para o Resolve e capítulos incorporados, com opção de manter ou substituir capítulos existentes.

### Importação de cartões de câmera

- Confira os clipes por pasta do cartão e data de gravação antes de importar.
- Marque explicitamente as continuações de gravação e, opcionalmente, divida os grupos após intervalos de mais de duas horas. As verificações de compatibilidade ajudam a identificar clipes que podem ser unidos.

### Acesso local de agentes

Ative **Settings → Agent Access**, autorize as pastas de origem e copie a configuração para seu cliente MCP. O auxiliar incluído permite que agentes naveguem e inspecionem mídias autorizadas, planejem conversões, enviem tarefas, acompanhem o progresso e cancelem tarefas na fila do app. Todos os 17 presets integrados estão disponíveis; presets FFmpeg personalizados ficam excluídos. As exportações IMF são experimentais.

Tarefas aceitas continuam após a desconexão do cliente. Os planos valem por 15 minutos, e os resultados de tarefas encerradas ficam disponíveis por 30 dias. Exportações feitas por agentes desativam o timecode de saída. Veja o [guia de configuração e fluxo de trabalho](../../Documentation/LOCAL_AGENT_ACCESS.md) para autorizações de pastas, configuração de clientes e recuperação de tarefas.

### Animações de formas de onda de áudio

- Gera animações de formas de onda para arquivos que contêm apenas áudio
- Cinco presets com opções de cor e normalização

### Capturas na resolução e profundidade de bits da origem

O botão de câmera no player de corte captura imagens na resolução original. O formato padrão é JPEG XL. Nas configurações, você pode escolher o formato por profundidade de bits e definir como tratar vídeos com canal alfa.

### Exportação e nomes de arquivos

- Por padrão, espaços e caracteres especiais são removidos. æ, ø e å são substituídos por ae, o e aa.
- Prévia do nome de arquivo processado
- Aviso se o arquivo já existe
- Após a codificação, um ícone mostra o arquivo convertido na pasta de exportação
- Outro ícone permite arrastar o resultado para outro aplicativo ou pasta
- Escolha do preset padrão nas configurações
- Escolha do local de exportação padrão

### Metadados

- Campo de comentário por arquivo para metadados opcionais, como créditos
- Tag de data opcional (Generated [YYYYMMDD]), prefixo e sufixo adicionados ao campo antes do comentário
- Visualização e comparação de metadados

### Aviso de reprodução automática aos 15 segundos para VideoLoop

Os navegadores costumam impedir a reprodução automática de vídeos longos em loop com som. O app mostra um ícone amarelo ⚠️ quando os presets VideoLoop são aplicados a clipes com mais de 15 segundos, para que você possa cortá-los ou escolher outro preset.

### App Intents

1. Adicionar à fila de codificação.
2. Converter vídeo imediatamente com o preset padrão.

---

## Presets de exportação

Todos os presets podem ser definidos como padrão na inicialização. Todos, exceto o padrão, podem ser ocultados do seletor.

#### Video Loop

Otimizado para loops contínuos e sem áudio. Codifica com x264 a CRF 23 (aproximadamente 3–9 Mbps de bitrate variável), remove o áudio e limita o lado mais curto a 1080 pixels para a web. Exibe um aviso quando o clipe ultrapassa 15 segundos.

#### Video Loop w/ Audio

As mesmas configurações x264, mas mantém todas as trilhas de áudio como AAC a 128 kbps. O lado mais curto continua limitado a 1080 pixels.

#### H.264 / AVC

Codificação H.264/AVC de ampla compatibilidade. Escolha VideoToolbox por hardware para mais velocidade ou libx264 por software com controle CRF para priorizar a qualidade. Contêineres MP4, MOV e MKV.

#### H.265 / HEVC

Codificação H.265/HEVC de 10 bits. VideoToolbox acelera a exportação por hardware; libx265 por software oferece alta eficiência de compressão.

#### AV1

Codificação SVT-AV1 com suporte a 10 bits e alta eficiência de compressão. Apenas por software, sem aceleração por hardware no macOS.

#### AV2 (experimental)

Codificação AV2 experimental com o codificador de referência AOM AVM incluído (`avmenc`), introduzida em uma versão de prévia. Suporta saída de 8/10 bits, qualidade constante ou bitrate variável, velocidade e resolução configuráveis. A codificação paralela por segmentos usa vários núcleos da CPU no modo de qualidade constante.

Escolha IVF (`.ivf`) apenas com vídeo ou Matroska (`.mkv`) com áudio AAC ou Opus. A codificação de referência é muito lenta, e o bitstream, ainda em evolução, exige um decodificador compatível com AV2. O app pode decodificar AV2 para conversões e miniaturas, mas ainda não oferece reprodução interativa. Use AV2 para experimentar, não como formato de entrega.

#### TV (HEVC 10-bit 4:2:2)

Formato de entrega para televisão com HEVC por hardware de 10 bits 4:2:2, resolução e taxa de quadros configuráveis, ajuste automático de bitrate e preservação de todos os canais de áudio como PCM de 24 bits.

#### TV (AVC-Intra)

Formato de televisão em contêiner MXF. AVC-Intra de 10 bits 4:2:2 com classes selecionáveis (50/100/200 Mbps), resolução e taxa de quadros, além de 4/8/16 canais mono de áudio PCM de 24 bits.

#### Stream copy

Copia os fluxos de áudio e vídeo existentes para um novo arquivo, preservando codecs, metadados e extensão originais. Útil para cortes e uniões.

#### ProRes

Apple ProRes (yuv422p10) para masters fáceis de editar. Inclui os primeiros fluxos de vídeo e áudio, mantém áudio PCM de 24 bits e usa os bitrates padrão do ProRes. O perfil padrão pode ser escolhido nas configurações dos presets.

#### Proxy

Cria proxies leves em HEVC, ProRes Proxy ou DNxHR com limites de resolução configuráveis. Mantém todos os canais de áudio como PCM sem compressão, ideal para edição offline e uma subpasta Proxy dedicada ao lado do material original.

#### DCP (Digital Cinema Package)

Exportação DCP conforme a SMPTE. Codifica vídeo como JPEG 2000 no espaço XYZ de 12 bits com conversão da entrada BT.709, encapsula em MXF com asdcp-wrap e gera todos os XML SMPTE necessários (CPL, PKL, ASSETMAP, VOLINDEX). Suporta 2K e 4K nos formatos Flat, Scope e Full a 24/25/30/48 fps, com bitrate configurável de 100–250 Mbps. O áudio é exportado como PCM de 24 bits em uma trilha MXF separada. Os metadados por item incluem título, tipo de conteúdo, anotação, classificação e idioma do áudio. Redimensionamento: ajustar com barras ou preencher recortando.

#### IMF App 2e / RDD 45 (experimental)

Exportação experimental de pacotes IMF com uma trilha de imagem e uma trilha de áudio PCM. Legendas no pacote e múltiplas trilhas de áudio não são suportadas. Valide cada pacote na ferramenta de masterização ou entrega de destino antes de usá-lo para entrega.

#### Image Sequence

Importa e exporta sequências em PNG, JPEG, TIFF, EXR, DPX, BMP, TGA, SGI, JPEG XL e JPEG 2000. Detecta automaticamente a numeração e aceita quadros ausentes. Arquivos de áudio podem ser associados para reprodução e exportação. A taxa de quadros pode ser configurada por sequência ou calculada a partir da duração do áudio associado. A exportação pode incluir arquivos auxiliares de metadados (Markdown ou JSON) com espaço de cor, codec e informações de câmera.

#### Animated Stills

Sequências animadas em GIF, AVIF ou PNG animado (APNG), selecionáveis nas configurações dos presets.

#### Audio Only AAC

Downmix estéreo em AAC que mantém a imagem estéreo e reduz significativamente o tamanho do arquivo.

#### Audio Only WAV

Exportação WAV sem compressão que preserva todos os canais de áudio sempre que possível.

#### 10 presets FFmpeg personalizados

Dez presets (C1–C10) permitem definir argumentos de saída, sufixos e extensões. Os parâmetros de entrada são tratados automaticamente. Caminhos com `-copy` não podem ser combinados com as opções de recorte de imagem ou remapeamento de áudio nas configurações dos presets.

#### [Tarefas pendentes / problemas conhecidos](../../TODO.md)

---

## Capturas de tela

#### Visualização da timeline do grupo

Veja uma sequência ao lado da lista de clipes, com miniaturas, formas de onda de áudio, alças de corte e timecode de saída. A timeline também oferece controles de divisão, marcadores, seleção de intervalos e zoom.

![Visualização da timeline do grupo](../screenshots/group-timeline.jpeg)

#### Visualização de corte de duração

![Visualização de corte de duração](https://github.com/user-attachments/assets/0a48088d-e770-402a-a989-dc93d9fcb2c8)

#### Visualização de recorte de imagem

![Visualização de recorte de imagem](https://github.com/user-attachments/assets/97745a95-7bda-43bf-873a-bd865e886690)

#### Remapeamento de áudio

![Remapeamento de áudio](https://github.com/user-attachments/assets/b7f0ab61-a6f1-4f90-8ec6-2f90b05c6022)

#### Visualização de downloads

![Visualização de downloads](https://github.com/user-attachments/assets/b2704580-464a-473d-9cac-9f1991ba4bb5)

#### Visualização de metadados

![Visualização de metadados](https://github.com/user-attachments/assets/77f2c209-bc92-4cca-8e6c-36414bb0ecf3)

#### Alteração do timecode

![Alteração do timecode](https://github.com/user-attachments/assets/7c3d951d-9bbb-402c-9984-2fe46fa7d713)

#### Configurações

![Configurações](https://github.com/user-attachments/assets/26b71bfa-e947-42c8-bc0c-4e3e66e81099)

#### Player em tela cheia

![Player em tela cheia](https://github.com/user-attachments/assets/c9af806f-279e-4a1c-a2ee-a4cae8572911)

---

## Requisitos

| | Mínimo |
|---|---|
| macOS | 15.0 (Sequoia) ou posterior |
| Hardware | Apple Silicon (M1 ou posterior) |

---

## Como usar

1. Abra o aplicativo.
2. Arraste arquivos de vídeo para a janela ou clique no botão mais para importá-los.
3. Selecione um **preset de exportação** na barra de ferramentas.
4. Clique no botão verde *Convert* ou pressione ⌘⏎.

Este é um projeto pessoal feito no tempo livre, pelo qual não recebo remuneração.

---

## Licença

Este projeto é distribuído sob a **GNU General Public License, versão 3.0**. Consulte [LICENSE](../../LICENSE) para ver o texto completo.

O binário FFmpeg incluído é compilado com `--enable-gpl` e tem licença **GPL v2 ou posterior**. Este projeto usa GPL v3 para todo o código, atendendo a esse requisito. Consulte a [licença original do FFmpeg](../../Licenses/ffmpeg-LICENSE.txt).

O binário asdcp-wrap incluído vem de [asdcplib](https://github.com/cinecert/asdcplib), de John Hurst, sob a **BSD 3-Clause License**. Consulte a [licença do asdcplib](../../Licenses/asdcplib-LICENSE.txt).

---

## Agradecimentos

O processamento de cor da exportação DCP se baseia na excelente documentação do [DCP-o-matic](https://dcpomatic.com/) sobre conversão para o espaço DCI XYZ. DCP-o-matic é uma ferramenta gratuita e de código aberto para criar DCPs: [projeto no GitHub](https://github.com/cth103/dcpomatic).

A inspeção de metadados e os recursos de autenticidade de conteúdo C2PA usam [SwiftMediaMetadata](https://github.com/aagedal/SwiftMediaMetadata).

---

PS! O app se chamava Aagedal VideoLoop Converter. Aagedal Media Converter é o mesmo aplicativo, com um nome que reflete melhor o que ele se tornou.
