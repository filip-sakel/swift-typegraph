// Lays out the UI graph (SPEC §2) with ELK: member nodes and pills are both
// ELK nodes, so pills sit between the rows of members as in the prototypes.

import type { ElkExtendedEdge, ElkNode } from 'elkjs/lib/elk.bundled.js'
import type { Graph } from '../api/types'

// ELK is most of the bundle; load it alongside the first analysis.
const elk = import('elkjs/lib/elk.bundled.js').then(({ default: ELK }) => new ELK())

export const NODE_FONT = '14px ui-monospace, SFMono-Regular, Menlo, Consolas, monospace'
export const PILL_FONT = '13px ui-monospace, SFMono-Regular, Menlo, Consolas, monospace'

let canvas: CanvasRenderingContext2D | null = null
function textWidth(text: string, font: string): number {
  canvas ??= document.createElement('canvas').getContext('2d')
  if (!canvas) return text.length * 8.4
  canvas.font = font
  return canvas.measureText(text).width
}

export interface LaidOutNode {
  id: string
  kind: 'root' | 'member' | 'pill'
  label: string
  x: number
  y: number
  width: number
  height: number
}

export interface LaidOutEdge {
  id: string
  points: { x: number; y: number }[]
  /** Into a member: drawn with an arrowhead. */
  arrow: boolean
  /** The pill this edge belongs to, for highlighting. */
  pill?: string
}

export interface Layout {
  nodes: LaidOutNode[]
  edges: LaidOutEdge[]
  width: number
  height: number
}

export const pillNodeId = (pillId: string) => `pill:${pillId}`

/** `label(memberId)` gives a member node's text. */
export async function layout(graph: Graph, label: (memberId: string) => string): Promise<Layout> {
  const kinds = new Map<string, LaidOutNode['kind']>()
  const labels = new Map<string, string>()
  const children: ElkNode[] = []
  const add = (id: string, kind: LaidOutNode['kind'], text: string) => {
    kinds.set(id, kind)
    labels.set(id, text)
    const font = kind === 'pill' ? PILL_FONT : NODE_FONT
    children.push({
      id,
      width: Math.ceil(textWidth(text, font)) + (kind === 'pill' ? 20 : 32),
      height: kind === 'pill' ? 24 : 36,
    })
  }

  add('root', 'root', graph.root.display)
  for (const m of graph.members) add(m.id, 'member', label(m.id))

  const edges: { id: string; sources: string[]; targets: string[] }[] = []
  const edgeIds = new Set<string>()
  const edgePill = new Map<string, string>()
  const connect = (from: string, to: string, pill?: string) => {
    const id = `e:${from}->${to}`
    if (edgeIds.has(id) || !kinds.has(from) || !kinds.has(to)) return
    edgeIds.add(id)
    edges.push({ id, sources: [from], targets: [to] })
    if (pill) edgePill.set(id, pill)
  }
  for (const p of graph.pills) {
    if (p.label !== '') add(pillNodeId(p.id), 'pill', p.label)
  }
  for (const p of graph.pills) {
    if (p.label === '') {
      // A plain line, e.g. root → a synthesized missing top-level member.
      for (const from of p.from) if (p.to) connect(from, p.to)
      continue
    }
    const node = pillNodeId(p.id)
    for (const from of p.from) connect(from, node, p.id)
    if (p.to) connect(node, p.to, p.id)
  }

  const result: ElkNode = await (await elk).layout({
    id: 'graph',
    layoutOptions: {
      'elk.algorithm': 'layered',
      'elk.direction': 'DOWN',
      'elk.edgeRouting': 'POLYLINE',
      'elk.spacing.nodeNode': '18',
      'elk.layered.spacing.nodeNodeBetweenLayers': '22',
      'elk.layered.spacing.edgeNodeBetweenLayers': '10',
      'elk.layered.nodePlacement.strategy': 'NETWORK_SIMPLEX',
      'elk.padding': '[top=24,left=24,bottom=24,right=24]',
    },
    children,
    edges,
  })

  return {
    nodes: (result.children ?? []).map((n) => ({
      id: n.id,
      kind: kinds.get(n.id)!,
      label: labels.get(n.id)!,
      x: n.x ?? 0,
      y: n.y ?? 0,
      width: n.width ?? 0,
      height: n.height ?? 0,
    })),
    edges: ((result.edges ?? []) as ElkExtendedEdge[]).flatMap((e) => {
      const section = e.sections?.[0]
      if (!section) return []
      const target = e.targets[0]
      return [
        {
          id: e.id,
          points: [section.startPoint, ...(section.bendPoints ?? []), section.endPoint],
          arrow: kinds.get(target) === 'member',
          pill: edgePill.get(e.id),
        },
      ]
    }),
    width: result.width ?? 0,
    height: result.height ?? 0,
  }
}
