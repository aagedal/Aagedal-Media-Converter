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
- **Análise** de loudness, silêncios, picos, fase estéreo e qualidade do vídeo codificado
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

### Ajustes

Clique com o botão direito em um arquivo na fila e escolha **Ajustes…** para configurar, por arquivo:
- **Girar** 90°/180° e **inverter** horizontal ou verticalmente (aplicado após o recorte de imagem e antes do redimensionamento do preset)
- **Velocidade** de 0,25× a 4× preservando o tom do áudio
- **Fade** de vídeo a partir do / para o preto, além de fade in e fade out de áudio
- **Deslocamento de áudio** para corrigir clipes fora de sincronia (valores positivos atrasam o áudio)
- **Substituir ou adicionar áudio** de outro arquivo, alinhado ao corte de duração e ajustado ao comprimento do vídeo
- **Gravar legendas na imagem** a partir de uma trilha de legenda de texto ou de um arquivo SRT, ASS ou VTT, com tamanho da fonte, contorno ou caixa e posição. Legendas baseadas em imagem (PGS, DVD) precisam passar primeiro por OCR de legendas para SRT.
- Substituição por arquivo da normalização de loudness

Os ajustes exigem um preset com recodificação; eles não estão disponíveis para Stream Copy, DCP, IMF, AV2, uniões ou vídeos gerados de formas de onda.

### Normalização de loudness

Ative **Normalize Loudness** em Configurações → Presets para normalizar cada trilha de áudio recodificada para EBU R128 (−23 LUFS, −1 dBTP), ATSC A/85, streaming (−14 LUFS), web/podcast (−16 LUFS) ou um alvo personalizado. Cada trilha é medida em uma primeira passagem e depois normalizada com o filtro `loudnorm` do FFmpeg usando ganho linear sempre que o programa permitir. Presets broadcast de trilhas mono, como AVC-Intra, são medidos por trilha de origem antes da divisão, preservando o equilíbrio estéreo.

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

Ative **Settings → Agent Access**, autorize as pastas de origem e copie a configuração para seu cliente MCP. O auxiliar incluído permite que agentes naveguem e inspecionem mídias autorizadas, planejem conversões, enviem tarefas, acompanhem o progresso e cancelem tarefas na fila do app. Estão disponíveis 21 presets integrados (todos os presets integrados, exceto Lossless FFV1); os slots FFmpeg personalizados ficam excluídos. As exportações IMF são experimentais.

Tarefas aceitas continuam após a desconexão do cliente. Os planos valem por 15 minutos, e os resultados de tarefas encerradas ficam disponíveis por 30 dias. Exportações feitas por agentes desativam o timecode de saída. Veja o [guia de configuração e fluxo de trabalho](../../Documentation/LOCAL_AGENT_ACCESS.md) para autorizações de pastas, configuração de clientes e recuperação de tarefas.

### Animações de formas de onda de áudio

- Gera animações de formas de onda para arquivos que contêm apenas áudio
- 7 estilos nativos em Swift (incluindo Halo, Orb, Ridgeline e LED Meter) mais 5 estilos clássicos do FFmpeg, com paletas de gradiente e opções de cor, opacidade, fundo transparente e normalização

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

### Análise de mídia

![Amostras verificadas de SSIMULACRA2 ao lado da reprodução da origem](../images/ssimulacra2-frame-inspection-en.png)
Abra o botão de gráfico em um arquivo da fila para inspecionar os relatórios de Áudio e Vídeo.

- Meça a loudness do programa inteiro e o pico verdadeiro (true peak) em trilhas individuais, pares mono personalizados ou grupos mono 5.1; exporte relatórios completos em JSON ou PDF.
- Encontre intervalos de silêncio e de pico, compare o equilíbrio entre canais ou verifique a correlação estéreo e o fold-down para mono. Salte para os trechos medidos na prévia pausada e exporte as medições completas em JSON.
- Encontre intervalos em preto (`blackdetect` do FFmpeg, com duração mínima, proporção de imagem e limiar de pixel ajustáveis) e cortes de cena (`scdet` do FFmpeg, com limiar ajustável e uma miniatura por corte) no vídeo de origem. Clique em um evento para inspecioná-lo na prévia pausada e exporte em JSON ou como marcadores EDL para o Resolve. Veja os formatos de relatório de [intervalos em preto](../../docs/video-black-report-format.md) e [cortes de cena](../../docs/video-scene-cut-report-format.md).
- Após a codificação, compare o vídeo com VMAF, PSNR, XPSNR ou amostras de SSIMULACRA2. Inspecione a qualidade ao longo do tempo, alterne entre a reprodução da origem e do resultado e salte para os trechos com menor pontuação.
- O SSIMULACRA2 compara quadros decodificados verificados até o limite selecionado, inclusive em clipes curtos. Os vídeos são indexados primeiro; mais amostras levam mais tempo.
- Exporte a qualidade do vídeo em JSON de resolução completa ou em PDF A4 paginado com timelines, pontuações por componente e avisos de comparação. Veja [interpretação de pontuações e detalhes do relatório](../../docs/video-quality-report-format.md).

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

O codificador e o decodificador incluídos usam AVM `1.0.0-445-g14342caad` (14 de outubro de 2026). As ferramentas continuam experimentais; veja a [validação de compilação e compatibilidade](../../docs/av2-integrated-encoder-2026-10-14.md) para consultar o código-fonte fixado, as instruções de recompilação e as verificações.

Escolha IVF (`.ivf`) apenas com vídeo ou Matroska (`.mkv`) com áudio AAC ou Opus. A codificação de referência é muito lenta e a reprodução exige um decodificador compatível com AV2. O app pode decodificar AV2 para conversões e miniaturas, mas ainda não oferece reprodução interativa. Use AV2 para experimentar, não como formato de entrega.

#### VP9 / WebM

VP9 livre de royalties para a web, codificado com libvpx em qualidade constante (CRF com alvo de bitrate zero) e multithreading por linhas. Escolha o CRF, uma velocidade de Best a Realtime, 8 bits (perfil 0) ou 10 bits (perfil 2) e um limite de resolução. O áudio é codificado em Opus em um bitrate selecionável. Gera WebM ou Matroska (`.mkv`). O Opus não consegue codificar alguns layouts de canal, como `5.1(side)`; faça o downmix dessas trilhas usando o remapeamento de áudio.

#### TV (HEVC 10-bit 4:2:2)

Formato de entrega para televisão com HEVC por hardware de 10 bits 4:2:2, resolução e taxa de quadros configuráveis, ajuste automático de bitrate e preservação de todos os canais de áudio como PCM de 24 bits.

#### TV (AVC-Intra)

Formato de televisão em contêiner MXF. AVC-Intra de 10 bits 4:2:2 com classes selecionáveis (50/100/200 Mbps), resolução e taxa de quadros, além de 4/8/16 canais mono de áudio PCM de 24 bits.

#### XDCAM HD422 (MXF)

Entrega broadcast Sony XDCAM HD422: MPEG-2 4:2:2 Profile @ High Level, 50 Mbps CBR long GOP (GOPs fechados de 12 quadros em 25/50 Hz e 15 em 29,97/59,94 Hz, dois B-frames) em um arquivo MXF OP1a. Escolha 1080i50, 1080p25, 1080i59.94, 1080p29.97, 720p50 ou 720p59.94. As origens são redimensionadas com pillarbox ou letterbox para raster completo 16:9, e o áudio é entregue em 4 ou 8 trilhas mono PCM de 24 bits a 48 kHz.

#### Stream copy

Copia os fluxos de áudio e vídeo existentes para um novo arquivo, preservando codecs, metadados e extensão originais. Útil para cortes e uniões.

#### ProRes

Apple ProRes (yuv422p10) para masters fáceis de editar. Inclui os primeiros fluxos de vídeo e áudio, mantém áudio PCM de 24 bits e usa os bitrates padrão do ProRes. O perfil padrão pode ser escolhido nas configurações dos presets.

#### DNxHR

Avid DNxHR na resolução de origem para edição e masterização: LB, SQ ou HQ (8 bits 4:2:2), HQX (10 bits 4:2:2) ou 444 (10 bits 4:4:4). Escolha um contêiner MOV ou MXF. Todas as trilhas de áudio são mantidas como PCM de 24 bits (reamostradas para 48 kHz em MXF).

#### CineForm

GoPro CineForm na resolução de origem em contêiner MOV, para edição e finalização: YUV de 10 bits 4:2:2, RGB de 12 bits 4:4:4 ou RGB de 12 bits 4:4:4 com alfa. Escolha uma qualidade de Low até Film Scan 3+ (Film Scan 1 por padrão). O codec armazena no máximo 12 bits por canal, portanto origens de 16 bits são reduzidas para 12 bits. O codificador do FFmpeg exige uma largura múltipla de 16, então outras larguras recebem preenchimento preto nas laterais. Todas as trilhas de áudio são mantidas como PCM de 24 bits.

#### Proxy

Cria proxies leves em HEVC, ProRes Proxy ou DNxHR com limites de resolução configuráveis. Mantém todos os canais de áudio como PCM sem compressão, ideal para edição offline e uma subpasta Proxy dedicada ao lado do material original.

#### DCP (Digital Cinema Package)

Exportação de Digital Cinema Package. Codifica vídeo como JPEG 2000 no espaço XYZ de 12 bits com conversão da entrada BT.709, encapsula em MXF com asdcp-wrap e gera os XML do pacote (CPL, PKL, ASSETMAP, VOLINDEX). Suporta 2K e 4K nos formatos Flat, Scope e Full a 24/25/30/48 fps, com bitrate configurável de 100–250 Mbps. O áudio é exportado como PCM de 24 bits em uma trilha MXF separada. Os metadados por item incluem título, tipo de conteúdo, anotação, classificação e idioma do áudio. Redimensionamento: ajustar com barras ou preencher recortando.

#### IMF App 2e / RDD 45 (experimental)

Exportação experimental de pacotes IMF com uma trilha de imagem e uma trilha de áudio PCM. Legendas no pacote e múltiplas trilhas de áudio não são suportadas. Valide cada pacote na ferramenta de masterização ou entrega de destino antes de usá-lo para entrega.

#### Image Sequence

Importa e exporta sequências em PNG, JPEG, TIFF, EXR, DPX, BMP, TGA, SGI, JPEG XL e JPEG 2000. Detecta automaticamente a numeração e aceita quadros ausentes. Arquivos de áudio podem ser associados para reprodução e exportação. A taxa de quadros pode ser configurada por sequência ou calculada a partir da duração do áudio associado. A exportação pode incluir arquivos auxiliares de metadados (Markdown ou JSON) com espaço de cor, codec e informações de câmera.

#### Animated Stills

Sequências animadas em GIF, AVIF, PNG animado (APNG), WebP animado ou JPEG XL animado, selecionáveis nas configurações dos presets.

#### Lossless (FFV1)

Codificação de arquivamento FFV1 matematicamente sem perdas em Matroska (`.mkv`) com áudio PCM sem compressão.

#### Audio Only

Extrai ou transcodifica áudio como WAV (PCM sem compressão mantendo todos os canais), FLAC, ALAC ou AAC/MP4, configurável nas configurações dos presets.

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

A interface do aplicativo oferece suporte a inglês, norueguês bokmål, alemão, espanhol, francês, italiano, japonês, coreano, português do Brasil e chinês simplificado. Ela segue o idioma preferido do app definido nos Ajustes do Sistema do macOS. As oito traduções recém-adicionadas são uma primeira versão; as strings que aguardam revisão linguística estão marcadas como **Needs Review** em `Aagedal Media Converter/Resources/Localizable.xcstrings`.

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
