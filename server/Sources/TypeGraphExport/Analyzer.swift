import SwiftDiagnostics
import SwiftIfConfig
@_spi(_QualifiedLookup) @_spi(_QualifiedLookupTests) import SwiftLexicalLookup
import SwiftParser
import SwiftParserDiagnostics
import SwiftSyntax

public enum Analyzer {
  public static let moduleName = "MyModule"
  public static let fileName = "main.swift"

  /// Runs SPEC §5.4 steps 1-6 on `source`.
  public static func analyze(source: String, checkInvariants: Bool) -> AnalyzeResponse {
    let lines = LineTable(source: source)
    let tree = Parser.parse(source: source)

    // 1. Lookup doesn't run on a tree with syntax errors.
    let diagnostics = ParseDiagnosticsGenerator.diagnostics(for: tree)
    if diagnostics.contains(where: { $0.diagMessage.severity == .error }) {
      return AnalyzeResponse(
        status: .parseErrors,
        diagnostics: diagnostics.map { diagnostic in
          let node = diagnostic.node
          let range =
            node.positionAfterSkippingLeadingTrivia < node.endPositionBeforeTrailingTrivia
            ? lines.range(node) : lines.range(diagnostic.position, diagnostic.position)
          return Diagnostic(range: range, severity: severity(diagnostic.diagMessage.severity), message: diagnostic.message)
        }
      )
    }

    // 2-4.
    let module = Identifier(canonicalName: "MyModule")
    let symbolTable = SymbolTable(
      moduleName: module,
      moduleToSources: [module: [fileName: tree]],
      buildConfiguration: StaticBuildConfiguration(
        customConditions: [],
        languageVersion: VersionTuple(6, 0),
        compilerVersion: VersionTuple(6, 2)
      )
    )!
    let syntax = SyntaxCollector(viewMode: .sourceAccurate)
    syntax.walk(tree)

    symbolTable.admitExtensions(accessibleFrom: tree)
    for nominal in syntax.nominals {
      _ = symbolTable.resolve(nominalTypeDecl: Attached(nominal)!)
    }
    let typeResults = syntax.typeSyntaxes.map { symbolTable.resolve(typeSyntax: Attached($0)!) }

    // 5.
    var exporter = Exporter(symbolTable: symbolTable, syntax: syntax, lines: lines)
    let graph = exporter.export(typeResults: typeResults)

    // 6.
    let violation = checkInvariants ? symbolTable.typeGraph._firstInvariantViolation(symbolTable: symbolTable) : nil
    return AnalyzeResponse(status: .ok, graph: graph, invariantViolation: violation.map { "\($0)" })
  }

  private static func severity(_ severity: DiagnosticSeverity) -> Diagnostic.Severity {
    switch severity {
    case .error: .error
    case .warning: .warning
    default: .note
    }
  }
}

// MARK: Syntax collection

/// Declaration groups, nominal types and type syntax, in source order.
final class SyntaxCollector: SyntaxAnyVisitor {
  var declGroups: [DeclGroupSyntaxType] = []
  var nominals: [NominalTypeDeclSyntax] = []
  /// Type syntax outside of extended types (SPEC §6.4: the extended type selects its extension).
  var typeSyntaxes: [TypeSyntax] = []
  /// Type declarations at file scope.
  var topLevelTypeDecls: [TypeDeclSyntax] = []

  override func visit(_ node: SourceFileSyntax) -> SyntaxVisitorContinueKind {
    topLevelTypeDecls = node.statements.compactMap { TypeDeclSyntax($0.item) }.filter { !$0.is(GenericParameterSyntax.self) }
    return .visitChildren
  }

  override func visitAny(_ node: Syntax) -> SyntaxVisitorContinueKind {
    if let group = DeclGroupSyntaxType(node) {
      declGroups.append(group)
      if let nominal = NominalTypeDeclSyntax(node) { nominals.append(nominal) }
    }
    if let type = node.as(TypeSyntax.self) {
      if node.parent?.is(ExtensionDeclSyntax.self) == true, node.keyPathInParent == \ExtensionDeclSyntax.extendedType {
        return .skipChildren
      }
      typeSyntaxes.append(type)
    }
    return .visitChildren
  }
}

// MARK: Export

private typealias GlobalTypeName = TypeGraph.GlobalTypeName

private struct Exporter {
  let symbolTable: SymbolTable
  let syntax: SyntaxCollector
  let lines: LineTable
  var graph: TypeGraph { symbolTable.typeGraph }

  /// `DeclGroup.id` by syntax node.
  private var groupIds: [SyntaxIdentifier: String] = [:]
  private var groupLabels: [SyntaxIdentifier: String] = [:]
  /// Admitted names by main declaration (SPEC §2.1, Admits).
  private var admittedNames: [SyntaxIdentifier: GlobalTypeName] = [:]
  private var members: [String: MemberBuilder] = [:]
  /// `MemberNode.id` of each type declaration.
  private var memberOfDecl: [SyntaxIdentifier: String] = [:]

  private final class MemberBuilder {
    let id: String
    let base: GlobalTypeName?
    let name: String
    var decls: [(decl: TypeDeclSyntax, parent: String)] = []
    /// Where it's first declared or looked up, for sorting.
    var firstOffset: Int

    init(id: String, base: GlobalTypeName?, name: String, firstOffset: Int) {
      self.id = id
      self.base = base
      self.name = name
      self.firstOffset = firstOffset
    }
  }

  init(symbolTable: SymbolTable, syntax: SyntaxCollector, lines: LineTable) {
    self.symbolTable = symbolTable
    self.syntax = syntax
    self.lines = lines
  }

  mutating func export(typeResults: [TypeResolver.TypeResult]) -> Graph {
    assignGroupIds()
    let names = graph.namesToTypes.keys.sorted { $0.debugDescription < $1.debugDescription }
    for name in names {
      admittedNames[graph.namesToTypes[name]!.mainDecl.node.id] = name
    }
    collectMembers(sortedNames: names)

    // Extensions: their dependencies and missing members (SPEC §2.2).
    var failedExtensionAnchors: [SyntaxIdentifier: String] = [:]
    for group in syntax.declGroups {
      guard let ext = group.as(ExtensionDeclSyntax.self), let state = extensionState(ext) else { continue }
      for dependency in state.dependencies {
        for member in dependency.members {
          addLookedUp(base: dependency.baseTypeName, name: member.name.name, at: ext)
        }
      }
      if case .failure(let failure) = state.resolvedType {
        collectMissing(failure, at: ext)
        if state.dependencies.isEmpty, let name = rootCauseNoTypeInScope(failure, extendedType: ext.extendedType) {
          addLookedUp(base: nil, name: name, at: ext)
          failedExtensionAnchors[ext.id] = memberId(base: nil, name: name)
        }
      }
    }

    let typeSyntaxInfos = zip(syntax.typeSyntaxes, typeResults).enumerated().map { index, pair in
      TypeSyntaxInfo(
        id: "ts#\(index)",
        range: lines.range(pair.0),
        text: pair.0.trimmedDescription,
        result: typeResultDTO(pair.1),
        owner: owner(of: Syntax(pair.0))
      )
    }
    let aliasResults: [SyntaxIdentifier: TypeResultDTO] = Dictionary(
      zip(syntax.typeSyntaxes, typeSyntaxInfos).compactMap { type, info in
        guard let alias = type.parent?.parent?.as(TypeAliasDeclSyntax.self), alias.initializer.value.id == type.id else {
          return nil
        }
        return (alias.id, info.result)
      },
      uniquingKeysWith: { first, _ in first }
    )

    let memberNodes = members.values
      .sorted { ($0.firstOffset, $0.id) < ($1.firstOffset, $1.id) }
      .map { memberNode($0, aliasResults: aliasResults) }

    let declGroups = syntax.declGroups.map(declGroupDTO)
    let pills = makePills(declGroups: declGroups, memberNodes: memberNodes, failedExtensionAnchors: failedExtensionAnchors)

    return Graph(
      root: Graph.Root(display: Analyzer.moduleName),
      members: memberNodes,
      declGroups: declGroups,
      pills: pills,
      typeSyntaxes: typeSyntaxInfos
    )
  }

  // MARK: Declaration groups

  private mutating func assignGroupIds() {
    var ordinals: [String: Int] = [:]
    for group in syntax.declGroups {
      let (kind, label) = kindAndLabel(group)
      let key = "\(kind):\(label.split(separator: " ", maxSplits: 1).last ?? "")"
      let ordinal = ordinals[key, default: 0]
      ordinals[key] = ordinal + 1
      groupIds[group.id] = "\(key)#\(ordinal)"
      groupLabels[group.id] = label
    }
  }

  private func kindAndLabel(_ group: DeclGroupSyntaxType) -> (String, String) {
    if let ext = group.as(ExtensionDeclSyntax.self) {
      return ("extension", "extension \(ext.extendedType.trimmedDescription)")
    }
    let nominal = NominalTypeDeclSyntax(group)!
    return (nominal.introducer.text, "\(nominal.introducer.text) \(nominal.name.text)")
  }

  private func extensionState(_ ext: ExtensionDeclSyntax) -> TypeGraph.ExtensionState? {
    Attached(ext).flatMap { graph.extensionsToState[$0] }
  }

  private func declGroupDTO(_ group: DeclGroupSyntaxType) -> DeclGroup {
    let id = groupIds[group.id]!
    let headerEnd = group.memberBlock.leftBrace.previousToken(viewMode: .sourceAccurate)?.endPositionBeforeTrailingTrivia
      ?? group.memberBlock.positionAfterSkippingLeadingTrivia
    var resolvedTo: DeclGroup.ResolvedTo?
    var dependencies: [String] = []
    if let ext = group.as(ExtensionDeclSyntax.self), let state = extensionState(ext) {
      switch state.resolvedType {
      case .success(let name): resolvedTo = .init(ok: true, type: typeName(name))
      case .failure(let failure): resolvedTo = .init(ok: false, failure: failureDTO(failure))
      }
      dependencies = state.dependencies.flatMap { dependency in
        dependency.members.map { memberId(base: dependency.baseTypeName, name: $0.name.name) }
      }
    }
    return DeclGroup(
      id: id,
      kind: kindAndLabel(group).0,
      label: groupLabels[group.id]!,
      range: lines.range(group),
      headerRange: lines.range(group.positionAfterSkippingLeadingTrivia, headerEnd),
      resolvedTo: resolvedTo,
      dependencies: dependencies,
      introduces: members.values
        .filter { $0.decls.contains { $0.parent == id } }
        .sorted { ($0.firstOffset, $0.id) < ($1.firstOffset, $1.id) }
        .map(\.id)
    )
  }

  // MARK: Members

  private mutating func collectMembers(sortedNames: [GlobalTypeName]) {
    // Top-level types are members of the module (SPEC §2.1).
    for decl in syntax.topLevelTypeDecls {
      addDecl(decl, base: nil, parent: "root")
    }
    for name in sortedNames {
      let type = graph.namesToTypes[name]!
      let mainId = groupIds[type.mainDecl.node.id] ?? "root"
      addTable(type.mainDeclMembers, base: name, parent: mainId)
      for module in type.boundExtensions.keys.sorted(by: { $0.name < $1.name }) {
        let extensions = type.boundExtensions[module]!
        for ext in extensions.keys.sorted(by: { $0.node.position < $1.node.position }) {
          addTable(extensions[ext]!, base: name, parent: groupIds[ext.node.id] ?? "root")
        }
      }
    }
  }

  private mutating func addTable(_ table: TypeGraph.TypeTable, base: GlobalTypeName, parent: String) {
    for name in table.typeMembersToDecls.keys.sorted(by: { $0.name < $1.name }) {
      for decl in table.typeMembersToDecls[name]! {
        addDecl(decl.node, base: base, parent: parent)
      }
    }
  }

  private mutating func addDecl(_ decl: TypeDeclSyntax, base: GlobalTypeName?, parent: String) {
    let member = builder(base: base, name: decl.name.text, offset: decl.positionAfterSkippingLeadingTrivia.utf8Offset)
    guard !member.decls.contains(where: { $0.decl.id == decl.id }) else { return }
    member.decls.append((decl, parent))
    member.firstOffset = min(member.firstOffset, decl.positionAfterSkippingLeadingTrivia.utf8Offset)
    memberOfDecl[decl.id] = member.id
  }

  /// A member some extension looked up; creates a `missing` node if it has no declarations.
  private mutating func addLookedUp(base: GlobalTypeName?, name: String, at ext: some SyntaxProtocol) {
    _ = builder(base: base, name: name, offset: ext.positionAfterSkippingLeadingTrivia.utf8Offset)
  }

  private mutating func builder(base: GlobalTypeName?, name: String, offset: Int) -> MemberBuilder {
    let id = memberId(base: base, name: name)
    if let existing = members[id] { return existing }
    let member = MemberBuilder(id: id, base: base, name: name, firstOffset: offset)
    members[id] = member
    return member
  }

  private func memberId(base: GlobalTypeName?, name: String) -> String {
    "\(base?.debugDescription ?? "root") > \(name)"
  }

  private func memberNode(_ member: MemberBuilder, aliasResults: [SyntaxIdentifier: TypeResultDTO]) -> MemberNode {
    let decls = member.decls.sorted { $0.decl.position < $1.decl.position }
    let status: MemberNode.Status = decls.isEmpty ? .missing : decls.count == 1 ? .resolved : .ambiguous

    var admits = MemberNode.Admits(ok: false)
    var resolvedTo: TypeResultDTO?
    switch decls.count {
    case 0: admits.reason = .missing
    case 1:
      let decl = decls[0].decl
      if let name = admittedNames[decl.id] {
        admits = .init(ok: true, type: typeName(name))
        resolvedTo = .nominal(types: [typeName(name)])
      } else if NominalTypeDeclSyntax(decl) == nil {
        admits.reason = .notNominal
        resolvedTo = aliasResults[decl.id]
      } else {
        admits.reason = .notAdmitted
      }
    default: admits.reason = .redeclared
    }

    let dependents = member.base.flatMap { graph.namesToTypes[$0] }?.dependents
      .filter { $0.memberType.name == member.name }
      .compactMap { groupIds[$0.dependentExtension.node.id] } ?? []

    return MemberNode(
      id: member.id,
      base: member.base.map(typeName),
      name: member.name,
      status: status,
      decls: decls.map { decl, parent in
        MemberNode.Decl(
          kind: declKind(decl),
          range: lines.range(decl),
          nameRange: lines.range(decl.name),
          parent: parent
        )
      },
      admits: admits,
      resolvedTo: resolvedTo,
      dependents: Array(Set(dependents)).sorted()
    )
  }

  private func declKind(_ decl: TypeDeclSyntax) -> String {
    switch decl.kind {
    case .structDecl: "struct"
    case .classDecl: "class"
    case .enumDecl: "enum"
    case .actorDecl: "actor"
    case .protocolDecl: "protocol"
    case .typeAliasDecl: "typealias"
    case .associatedTypeDecl: "associatedtype"
    default: "\(decl.kind)"
    }
  }

  // MARK: Pills (SPEC §2.2)

  private func makePills(
    declGroups: [DeclGroup],
    memberNodes: [MemberNode],
    failedExtensionAnchors: [SyntaxIdentifier: String]
  ) -> [Pill] {
    var pills: [Pill] = []
    func add(_ label: String, _ selects: Pill.Selects, from: [String], to: String?, struck: Bool = false) {
      pills.append(Pill(id: "\(selects.id)|\(to ?? "")", label: label, selects: selects, from: from, to: to, struck: struck))
    }
    let groupsById = Dictionary(uniqueKeysWithValues: declGroups.map { ($0.id, $0) })

    // Top-level declarations hang off the module root.
    for decl in syntax.topLevelTypeDecls {
      let member = memberOfDecl[decl.id]!
      if let group = groupIds[decl.id] {
        add(groupLabels[decl.id]!, .init(kind: .declGroup, id: group), from: ["root"], to: member)
      } else {
        add("\(declKind(decl)) \(decl.name.text)", .init(kind: .member, id: member), from: ["root"], to: member)
      }
    }

    // Missing members, by the main declaration of their base type.
    var missingByBase: [String: [MemberNode]] = [:]
    for member in memberNodes where member.status == .missing {
      if let base = member.base { missingByBase[base.id, default: []].append(member) }
    }

    for group in syntax.declGroups {
      let dto = groupsById[groupIds[group.id]!]!
      let selects = Pill.Selects(kind: .declGroup, id: dto.id)

      if let nominal = NominalTypeDeclSyntax(group) {
        guard let name = admittedNames[nominal.id] else { continue }
        let admitting = memberId(base: name.base, name: name.components.last!.name)
        for member in dto.introduces {
          add(dto.label, selects, from: [admitting], to: member)
        }
        for missing in missingByBase[name.debugDescription] ?? [] {
          add(dto.label, selects, from: [admitting], to: missing.id)
        }
        continue
      }

      // Extensions
      switch dto.resolvedTo {
      case .some(let resolved) where resolved.ok:
        let from = dto.dependencies.isEmpty ? [resolved.type!.member!] : dto.dependencies
        if dto.introduces.isEmpty {
          add(dto.label, selects, from: from, to: nil)
        }
        for member in dto.introduces {
          add(dto.label, selects, from: from, to: member)
        }
      case .some:
        var from = dto.dependencies
        if from.isEmpty, let anchor = failedExtensionAnchors[group.id] {
          from = [anchor]
          // A plain line joins the synthesized missing node to the root.
          if !pills.contains(where: { $0.to == anchor && $0.from == ["root"] }) {
            add("", .init(kind: .member, id: anchor), from: ["root"], to: anchor)
          }
        }
        add(dto.label, selects, from: from, to: nil, struck: true)
      case .none:
        // Not at file scope: never admitted.
        add(dto.label, selects, from: [], to: nil, struck: true)
      }
    }
    return pills
  }

  // MARK: Type names and results

  private func typeName(_ name: GlobalTypeName) -> TypeName {
    let components = name.components
    var simple: [String] = []
    var full = name.debugDescription
    switch components[0].qualifier {
    case .internal:
      simple.append(Analyzer.moduleName)
      full = "\(Analyzer.moduleName).\(full)"
    case .external(let module):
      simple.append(module)
    }
    simple.append(contentsOf: components.map(\.name))
    return TypeName(
      id: name.debugDescription,
      full: full,
      simple: simple.joined(separator: "."),
      member: memberId(base: name.base, name: components.last!.name)
    )
  }

  private func typeResultDTO(_ result: TypeResolver.TypeResult) -> TypeResultDTO {
    switch result {
    case .function(let argumentCount): .function(argumentCount: argumentCount)
    case .tuple(let labels): .tuple(labels: labels.map { $0?.name })
    case .anyType: .any
    case .metatype(let base): .metatype(base: typeResultDTO(base))
    case .nominalTypes(let types): .nominal(types: types.map { typeName($0.type) })
    case .failure(let failure): .failure(failureDTO(failure))
    }
  }

  private func typeName(_ ref: TypeGraph.TypeRef) -> TypeName {
    switch ref {
    case .global(let global):
      return typeName(global.name)
    case .local(let decl):
      let name = decl.node.name.text
      return TypeName(id: "local:\(lines.pos(decl.node.position).line):\(name)", full: name, simple: name, member: nil)
    }
  }

  // MARK: Failures

  private typealias Failure = TypeResolver.Failure

  /// Registers missing members named by `noTypeMember` failures.
  private mutating func collectMissing(_ failure: Failure, at ext: ExtensionDeclSyntax) {
    switch failure {
    case .noTypeMember(let member, let base):
      if case .nominalTypes(let types) = base, types.count == 1, case .global(let ref) = types[0].type {
        addLookedUp(base: ref.name, name: member.name.name, at: ext)
      }
    case .nested(let nested):
      for child in children(nested) { collectMissing(child, at: ext) }
    default:
      break
    }
  }

  /// The leftmost name of `extendedType` if `failure` bottoms out at `noTypeInScope`.
  private func rootCauseNoTypeInScope(_ failure: Failure, extendedType: TypeSyntax) -> String? {
    switch failure {
    case .noTypeInScope:
      var type = extendedType
      while let member = type.as(MemberTypeSyntax.self) { type = member.baseType }
      return type.as(IdentifierTypeSyntax.self)?.name.text
    case .nested(.invalidBaseType(let base)):
      return rootCauseNoTypeInScope(base, extendedType: extendedType)
    default:
      return nil
    }
  }

  private func children(_ nested: TypeResolver.NestedFailure) -> [Failure] {
    switch nested {
    case .invalidAliasedType(let failure), .invalidBaseType(let failure): [failure]
    case .invalidMembers(let members): members.map(\.1)
    case .invalidComposition(let types): types.map(\.1)
    }
  }

  private func failureDTO(_ failure: Failure) -> FailureDTO {
    var dto = FailureDTO(kind: "", message: failure.debugDescription, ranges: [], members: [], children: [])
    switch failure {
    case .invalidNameToken(let token):
      dto.kind = "invalidNameToken"
      dto.ranges = [lines.range(token)]
    case .noTypeInScope:
      dto.kind = "noTypeInScope"
    case .cannotComposeNonClassOrProtocol:
      dto.kind = "cannotComposeNonClassOrProtocol"
    case .noTypeMember(let member, let base):
      dto.kind = "noTypeMember"
      dto.ranges = [lines.range(member.introducingSyntax.node)]
      if case .nominalTypes(let types) = base, types.count == 1, case .global(let ref) = types[0].type {
        dto.members = [memberId(base: ref.name, name: member.name.name)]
      }
    case .cannotExtendNonNominal:
      dto.kind = "cannotExtendNonNominal"
    case .extensionNotAtFileScope(let ext):
      dto.kind = "extensionNotAtFileScope"
      dto.ranges = [lines.range(ext)]
    case .partialTypeResolutionFailure:
      dto.kind = "partialTypeResolutionFailure"
    case .genericParameterOrAssociatedType:
      dto.kind = "genericParameterOrAssociatedType"
    case .ambiguousTypeDecl(let decls):
      dto.kind = "ambiguousTypeDecl"
      dto.ranges = decls.map { lines.range($0) }
      dto.members = Array(Set(decls.compactMap { memberOfDecl[$0.id] })).sorted()
    case .syntaxNotInSymbolTable:
      dto.kind = "syntaxNotInSymbolTable"
    case .syntaxInDisabledRegion:
      dto.kind = "syntaxInDisabledRegion"
    case .cyclicalTypeReference(let cycle):
      dto.kind = "cyclicalTypeReference"
      dto.ranges = cycle.map { lines.range($0) }
    case .cyclicalExtensionDependency(let cycle):
      dto.kind = "cyclicalExtensionDependency"
      dto.ranges = cycle.dependencyPath.map { lines.range($0.extensionDecl) }
    case .extensionNotBoundYet:
      dto.kind = "extensionNotBoundYet"
    case .nested(let nested):
      switch nested {
      case .invalidAliasedType: dto.kind = "invalidAliasedType"
      case .invalidBaseType: dto.kind = "invalidBaseType"
      case .invalidMembers(let members):
        dto.kind = "invalidMembers"
        dto.ranges = members.map { lines.range($0.0) }
      case .invalidComposition(let types):
        dto.kind = "invalidComposition"
        dto.ranges = types.map { lines.range($0.0) }
      }
      dto.children = children(nested).map(failureDTO)
    }
    return dto
  }

  // MARK: Ownership

  private func owner(of node: Syntax) -> String {
    var current = node.parent
    while let ancestor = current {
      if let id = groupIds[ancestor.id] { return id }
      current = ancestor.parent
    }
    return "root"
  }
}
