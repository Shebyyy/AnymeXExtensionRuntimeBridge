import 'dart:convert';
import 'dart:io';

import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;
import 'package:pseudom/pseudom.dart' as pseudom;
import 'package:xpath_selector_html_parser/xpath_selector_html_parser.dart';
import 'package:flutter_qjs/flutter_qjs.dart';

import '../../../Logger.dart';
import 'Models/LegadoSource.dart';

/// Core Legado rule evaluation engine.
/// Handles all 5 rule syntaxes: JSOUP Default, CSS, XPath, JSONPath, JavaScript
/// Plus special operators: &&, ||, %%, ##regex##
class LegadoRuleEngine {
  final LegadoSource source;
  final String baseUrl;
  String? _userAgent;

  LegadoRuleEngine(this.source)
      : baseUrl = source.bookSourceUrl ?? '' {
    _parseHeaders();
  }

  void _parseHeaders() {
    try {
      if (source.header != null && source.header!.isNotEmpty) {
        final headerMap = jsonDecode(source.header!);
        if (headerMap is Map) {
          final ua = headerMap['User-Agent'];
          if (ua != null) {
            _userAgent = ua.toString();
          }
        }
      }
    } catch (_) {}
  }

  // ============================================================
  // HTTP REQUEST HANDLING
  // ============================================================

  Future<String> fetchUrl(String url, {Map<String, String>? extraHeaders, String? body, String? method}) async {
    final resolved = resolveUrl(url);
    final uri = Uri.parse(resolved);

    final headers = <String, String>{};
    if (_userAgent != null) headers['User-Agent'] = _userAgent!;
    if (source.header != null && source.header!.isNotEmpty) {
      try {
        final h = jsonDecode(source.header!);
        if (h is Map) {
          h.forEach((k, v) => headers[k.toString()] = v.toString());
        }
      } catch (_) {}
    }
    if (extraHeaders != null) headers.addAll(extraHeaders);
    if (headers['Referer'] == null) headers['Referer'] = baseUrl;

    final client = HttpClient();
    try {
      final req = await client.openUrl(method ?? (body != null ? 'POST' : 'GET'), uri);
      headers.forEach((k, v) => req.headers.set(k, v));
      if (body != null) {
        req.write(body);
      }
      final resp = await req.close();
      final responseBody = await resp.transform(utf8.decoder).join();
      return responseBody;
    } catch (e) {
      Logger.log('Legado: fetchUrl failed for $resolved: $e');
      rethrow;
    } finally {
      client.close();
    }
  }

  /// Resolve a potentially relative URL against the base URL
  String resolveUrl(String url) {
    if (url.isEmpty) return baseUrl;
    if (url.startsWith('http://') || url.startsWith('https://')) return url;
    if (url.startsWith('//')) return 'https:$url';
    if (url.startsWith('/')) {
      final base = Uri.parse(baseUrl);
      return '${base.scheme}://${base.host}$url';
    }
    return '$baseUrl/$url';
  }

  // ============================================================
  // URL TEMPLATE RESOLUTION
  // ============================================================

  /// Resolve URL templates like: /search?q={{key}}&page={{page}}
  /// Also handles POST format: url,{"method":"POST","body":"key={{key}}"}
  ResolvedUrl resolveUrlTemplate(
    String urlTemplate, {
    String? key,
    int? page,
    Map<String, String>? extraVars,
  }) {
    var template = urlTemplate;

    // Check for POST config appended to URL
    String? postBody;
    Map<String, String> extraHeaders = {};
    String method = 'GET';
    String? charset;

    // Format: url,{"method":"POST","body":"...","headers":{...},"charset":"gbk"}
    final postMatch = RegExp(r'^(.+?),(\{.+\})$').firstMatch(template);
    if (postMatch != null) {
      template = postMatch.group(1)!;
      try {
        final config = jsonDecode(postMatch.group(2)!) as Map<String, dynamic>;
        method = (config['method'] as String?)?.toUpperCase() ?? 'GET';
        postBody = config['body'] as String?;
        if (config['headers'] is Map) {
          (config['headers'] as Map).forEach(
              (k, v) => extraHeaders[k.toString()] = v.toString());
        }
        charset = config['charset'] as String?;
      } catch (e) {
        Logger.log('Legado: Failed to parse URL config: $e');
      }
    }

    // Replace template variables
    final vars = <String, String>{};
    if (key != null) vars['key'] = key;
    if (page != null) vars['page'] = page.toString();
    if (extraVars != null) vars.addAll(extraVars);

    // Handle <,{{page}}> pattern (omit page param when page=1)
    template = template.replaceAllMapped(
      RegExp(r'<,([^>]+)>'),
      (m) {
        final param = m.group(1)!;
        // If the variable is 1 or empty, omit it
        final varMatch = RegExp(r'\{\{(\w+)\}\}').firstMatch(param);
        if (varMatch != null) {
          final varName = varMatch.group(1)!;
          final value = vars[varName];
          if (value == '1' || value == null || value.isEmpty) {
            return '';
          }
        }
        return ',${param.replaceAll(RegExp(r'^&'), '')}';
      },
    );

    // Replace {{var}} with values
    vars.forEach((k, v) {
      template = template.replaceAll('{{$k}}', Uri.encodeComponent(v));
      // Also replace in postBody - URL-encode for form bodies, raw for JSON bodies
      if (postBody != null) {
        if (postBody!.startsWith('{') || postBody!.startsWith('[')) {
          // JSON body - keep raw value but escape for JSON
          postBody = postBody!.replaceAll('{{$k}}', v);
        } else {
          // Form body - URL-encode the value
          postBody = postBody!.replaceAll('{{$k}}', Uri.encodeComponent(v));
        }
      }
    });

    // Clean up remaining template vars
    template = template.replaceAll(RegExp(r'\{\{(\w+)\}\}'), '');

    return ResolvedUrl(
      url: template,
      method: method,
      body: postBody,
      headers: extraHeaders,
      charset: charset,
    );
  }

  // ============================================================
  // MAIN RULE EVALUATION
  // ============================================================

  /// Evaluate a rule string against content (HTML or JSON).
  /// Returns a string result.
  Future<String> evalRule(
    String content,
    String rule, {
    String? baseUrlOverride,
    Map<String, dynamic>? extraContext,
  }) async {
    if (rule.isEmpty) return '';

    // Handle || (OR - fallback) operator
    if (rule.contains('||')) {
      final parts = _splitOperators(rule, '||');
      for (final part in parts) {
        final result = await evalRule(content, part.trim(),
            baseUrlOverride: baseUrlOverride, extraContext: extraContext);
        if (result.isNotEmpty) return result;
      }
      return '';
    }

    // Handle && (AND - merge) operator
    if (rule.contains('&&')) {
      final parts = _splitOperators(rule, '&&');
      final results = <String>[];
      for (final part in parts) {
        final result = await evalRule(content, part.trim(),
            baseUrlOverride: baseUrlOverride, extraContext: extraContext);
        if (result.isNotEmpty) results.add(result);
      }
      return results.join('\n');
    }

    // Handle %% (interleave) operator
    if (rule.contains('%%')) {
      final parts = _splitOperators(rule, '%%');
      final results = <String>[];
      for (final part in parts) {
        final result = await evalRule(content, part.trim(),
            baseUrlOverride: baseUrlOverride, extraContext: extraContext);
        if (result.isNotEmpty) results.add(result);
      }
      return results.join('\n');
    }

    // Handle ##regex##replacement at the end
    String? replacePattern;
    String? replaceReplacement;
    final regexMatch = RegExp(r'##(.*?)##(.*)$').firstMatch(rule);
    if (regexMatch != null) {
      replacePattern = regexMatch.group(1);
      replaceReplacement = regexMatch.group(2) ?? '';
      rule = rule.substring(0, regexMatch.start);
    }

    String result;

    // Detect rule type
    if (rule.startsWith('@css:')) {
      result = _evalCssRule(content, rule.substring(5));
    } else if (rule.startsWith('@xpath:')) {
      result = _evalXPathRule(content, rule.substring(7));
    } else if (rule.startsWith('@json:') || rule.startsWith('\$.')) {
      final jsonRule = rule.startsWith('@json:') ? rule.substring(6) : rule;
      result = _evalJsonPathRule(content, jsonRule);
    } else if (rule.startsWith('@js:') || rule.startsWith('<js>')) {
      final jsCode = rule.startsWith('@js:')
          ? rule.substring(4)
          : rule.replaceAll(RegExp(r'^<js>'), '').replaceAll(RegExp(r'</js>$'), '');
      result = await _evalJsRule(jsCode, content,
          baseUrlOverride: baseUrlOverride, extraContext: extraContext);
    } else if (rule.startsWith('//')) {
      result = _evalXPathRule(content, rule);
    } else {
      result = _evalJsoupDefaultRule(content, rule);
    }

    // Apply regex replacement
    if (replacePattern != null && replacePattern.isNotEmpty) {
      try {
        result = result.replaceAll(RegExp(replacePattern), replaceReplacement ?? '');
      } catch (e) {
        Logger.log('Legado: regex replace failed: $e');
      }
    }

    return result.trim();
  }

  /// Evaluate a rule that returns a list of elements (for bookList, chapterList etc.)
  Future<List<RuleElement>> evalRuleList(
    String content,
    String rule, {
    String? baseUrlOverride,
    Map<String, dynamic>? extraContext,
  }) async {
    if (rule.isEmpty) return [];

    // Detect rule type and return list of elements
    if (rule.startsWith('@css:')) {
      return _evalCssRuleList(content, rule.substring(5));
    } else if (rule.startsWith('@xpath:')) {
      return _evalXPathRuleList(content, rule.substring(7));
    } else if (rule.startsWith('@json:') || rule.startsWith('\$.')) {
      final jsonRule = rule.startsWith('@json:') ? rule.substring(6) : rule;
      return _evalJsonPathRuleList(content, jsonRule);
    } else if (rule.startsWith('//')) {
      return _evalXPathRuleList(content, rule);
    } else {
      return _evalJsoupDefaultRuleList(content, rule);
    }
  }

  /// Evaluate a rule against a single element (for extracting fields from book/chapter items)
  Future<String> evalRuleOnElement(
    RuleElement element,
    String rule, {
    String? baseUrlOverride,
    Map<String, dynamic>? extraContext,
  }) async {
    if (rule.isEmpty) return '';

    // Handle || (OR) operator
    if (rule.contains('||')) {
      final parts = _splitOperators(rule, '||');
      for (final part in parts) {
        final result = await evalRuleOnElement(element, part.trim(),
            baseUrlOverride: baseUrlOverride, extraContext: extraContext);
        if (result.isNotEmpty) return result;
      }
      return '';
    }

    // Handle && (AND) operator
    if (rule.contains('&&')) {
      final parts = _splitOperators(rule, '&&');
      final results = <String>[];
      for (final part in parts) {
        final result = await evalRuleOnElement(element, part.trim(),
            baseUrlOverride: baseUrlOverride, extraContext: extraContext);
        if (result.isNotEmpty) results.add(result);
      }
      return results.join('\n');
    }

    // Handle ##regex##replacement
    String? replacePattern;
    String? replaceReplacement;
    final regexMatch = RegExp(r'##(.*?)##(.*)$').firstMatch(rule);
    if (regexMatch != null) {
      replacePattern = regexMatch.group(1);
      replaceReplacement = regexMatch.group(2) ?? '';
      rule = rule.substring(0, regexMatch.start);
    }

    String result;

    if (rule.startsWith('@css:')) {
      result = _evalCssOnElement(element, rule.substring(5));
    } else if (rule.startsWith('@xpath:')) {
      result = _evalXPathOnElement(element, rule.substring(7));
    } else if (rule.startsWith('@json:') || rule.startsWith('\$.')) {
      final jsonRule = rule.startsWith('@json:') ? rule.substring(6) : rule;
      result = _evalJsonPathOnElement(element, jsonRule);
    } else if (rule.startsWith('@js:') || rule.startsWith('<js>')) {
      final jsCode = rule.startsWith('@js:')
          ? rule.substring(4)
          : rule.replaceAll(RegExp(r'^<js>'), '').replaceAll(RegExp(r'</js>$'), '');
      result = await _evalJsRule(jsCode, element.htmlContent,
          baseUrlOverride: baseUrlOverride, extraContext: extraContext);
    } else {
      result = _evalJsoupDefaultOnElement(element, rule);
    }

    if (replacePattern != null && replacePattern.isNotEmpty) {
      try {
        result = result.replaceAll(RegExp(replacePattern), replaceReplacement ?? '');
      } catch (e) {
        Logger.log('Legado: regex replace failed: $e');
      }
    }

    return result.trim();
  }

  // ============================================================
  // JSOUP DEFAULT RULE ENGINE
  // ============================================================

  /// JSOUP default rule: steps separated by @
  /// e.g., class.book-list.0@tag.div.0@tag.a.0@text
  String _evalJsoupDefaultRule(String content, String rule) {
    try {
      final doc = html_parser.parse(content);
      final steps = _parseJsoupSteps(rule);
      if (steps.isEmpty) return '';

      var elements = <dom.Element>[doc.documentElement!];
      String? getter;

      for (int i = 0; i < steps.length; i++) {
        final step = steps[i];
        if (i == steps.length - 1 && _isGetter(step)) {
          getter = step;
          break;
        }
        elements = _applyJsoupStep(elements, step);
        if (elements.isEmpty) return '';
      }

      if (getter != null && elements.isNotEmpty) {
        return _applyGetter(elements.first, getter);
      }
      return elements.isNotEmpty ? elements.first.text : '';
    } catch (e) {
      Logger.log('Legado: JSOUP default rule failed: $e');
      return '';
    }
  }

  List<RuleElement> _evalJsoupDefaultRuleList(String content, String rule) {
    try {
      final doc = html_parser.parse(content);
      final steps = _parseJsoupSteps(rule);
      if (steps.isEmpty) return [];

      var elements = <dom.Element>[doc.documentElement!];

      for (int i = 0; i < steps.length; i++) {
        final step = steps[i];
        if (i == steps.length - 1 && _isGetter(step)) {
          break;
        }
        elements = _applyJsoupStep(elements, step);
        if (elements.isEmpty) return [];
      }

      return elements.map((e) => RuleElement.fromDomElement(e, baseUrl: baseUrl)).toList();
    } catch (e) {
      Logger.log('Legado: JSOUP default rule list failed: $e');
      return [];
    }
  }

  String _evalJsoupDefaultOnElement(RuleElement element, String rule) {
    try {
      final el = element.asDomElement;
      if (el == null) return '';

      final steps = _parseJsoupSteps(rule);
      if (steps.isEmpty) return '';

      var elements = <dom.Element>[el];
      String? getter;

      for (int i = 0; i < steps.length; i++) {
        final step = steps[i];
        if (i == steps.length - 1 && _isGetter(step)) {
          getter = step;
          break;
        }
        elements = _applyJsoupStep(elements, step);
        if (elements.isEmpty) return '';
      }

      if (getter != null && elements.isNotEmpty) {
        return _applyGetter(elements.first, getter);
      }
      return elements.isNotEmpty ? elements.first.text : '';
    } catch (e) {
      return '';
    }
  }

  List<String> _parseJsoupSteps(String rule) {
    // Split by @ but not within <js>...</js> blocks
    final steps = <String>[];
    var current = StringBuffer();
    var inJs = false;

    for (int i = 0; i < rule.length; i++) {
      if (rule.substring(i).startsWith('<js>')) {
        inJs = true;
        current.write('<js>');
        i += 3;
        continue;
      }
      if (rule.substring(i).startsWith('</js>') && inJs) {
        inJs = false;
        current.write('</js>');
        i += 4;
        continue;
      }
      if (rule[i] == '@' && !inJs) {
        if (current.isNotEmpty) steps.add(current.toString());
        current = StringBuffer();
      } else {
        current.write(rule[i]);
      }
    }
    if (current.isNotEmpty) steps.add(current.toString());

    return steps;
  }

  bool _isGetter(String step) {
    const getters = {
      'text', 'html', 'innerHtml', 'outerHtml', 'href', 'src',
      'textNodes', 'ownText', 'content', 'all',
    };
    if (getters.contains(step)) return true;
    // If it's a plain attribute name (no dots or special prefixes)
    if (!step.contains('.') &&
        !step.startsWith('tag.') &&
        !step.startsWith('class.') &&
        !step.startsWith('id.') &&
        !step.startsWith('@css:') &&
        !step.startsWith('@xpath:') &&
        !step.startsWith('@json:') &&
        !step.startsWith('@js:') &&
        !step.startsWith('<js>') &&
        !step.startsWith('//') &&
        !step.startsWith('\$.')) {
      return true; // It's an attribute getter
    }
    return false;
  }

  List<dom.Element> _applyJsoupStep(List<dom.Element> elements, String step) {
    final result = <dom.Element>[];

    // tag.tagName.index or tag.tagName
    if (step.startsWith('tag.')) {
      final parts = step.split('.');
      if (parts.length >= 2) {
        final tagName = parts[1];
        final index = parts.length >= 3 ? int.tryParse(parts[2]) : null;
        for (final el in elements) {
          final found = el.getElementsByTagName(tagName);
          if (index != null) {
            if (index >= 0 && index < found.length) {
              result.add(found[index]);
            } else if (index < 0) {
              final actualIndex = found.length + index;
              if (actualIndex >= 0 && actualIndex < found.length) {
                result.add(found[actualIndex]);
              }
            }
          } else {
            result.addAll(found);
          }
        }
      }
      return result;
    }

    // class.className.index or class.className
    if (step.startsWith('class.')) {
      final parts = step.split('.');
      if (parts.length >= 2) {
        final className = parts[1];
        final index = parts.length >= 3 ? int.tryParse(parts[2]) : null;
        for (final el in elements) {
          final found = el.getElementsByClassName(className);
          if (index != null) {
            if (index >= 0 && index < found.length) {
              result.add(found[index]);
            } else if (index < 0) {
              final actualIndex = found.length + index;
              if (actualIndex >= 0 && actualIndex < found.length) {
                result.add(found[actualIndex]);
              }
            }
          } else {
            result.addAll(found);
          }
        }
      }
      return result;
    }

    // id.elementId
    if (step.startsWith('id.')) {
      final id = step.substring(3);
      for (final el in elements) {
        final found = _getElementById(el, id);
        if (found != null) result.add(found);
      }
      return result;
    }

    // CSS selector fallback - try as CSS selector (with wildcard support)
    try {
      for (final el in elements) {
        final found = _cssSelect(el, step);
        result.addAll(found);
      }
    } catch (e) {
      Logger.log('Legado: JSOUP step parse failed for "$step": $e');
    }

    return result;
  }

  String _applyGetter(dom.Element element, String getter) {
    switch (getter) {
      case 'text':
        return element.text.trim();
      case 'html':
      case 'innerHtml':
        return element.innerHtml;
      case 'outerHtml':
        return element.outerHtml;
      case 'href':
        final href = element.attributes['href'] ?? '';
        return resolveUrl(href);
      case 'src':
        final src = element.attributes['src'] ?? '';
        return resolveUrl(src);
      case 'textNodes':
        return element.nodes
            .whereType<dom.Text>()
            .map((t) => t.text)
            .join('\n');
      case 'ownText':
        return element.nodes
            .whereType<dom.Text>()
            .map((t) => t.text)
            .join();
      case 'content':
        return element.text.trim();
      case 'all':
        return element.outerHtml;
      default:
        // Try as an attribute name
        final attr = element.attributes[getter] ?? '';
        if (attr.isNotEmpty && (getter == 'href' || getter == 'src' || attr.startsWith('/'))) {
          return resolveUrl(attr);
        }
        return attr;
    }
  }

  dom.Element? _getElementById(dom.Element root, String id) {
    if (root.id == id) return root;
    for (final child in root.children) {
      final found = _getElementById(child, id);
      if (found != null) return found;
    }
    return null;
  }

  // ============================================================
  // CSS SELECTOR RULE ENGINE
  // ============================================================

  String _evalCssRule(String content, String cssRule) {
    try {
      final doc = html_parser.parse(content);
      final steps = cssRule.split('@');
      if (steps.isEmpty) return '';

      final selector = steps[0];
      final getter = steps.length > 1 ? steps[1] : 'text';

      final element = _cssSelectFirst(doc.documentElement!, selector);
      if (element == null) return '';

      return _applyGetter(element, getter);
    } catch (e) {
      Logger.log('Legado: CSS rule failed: $e');
      return '';
    }
  }

  List<RuleElement> _evalCssRuleList(String content, String cssRule) {
    try {
      final doc = html_parser.parse(content);
      // The CSS rule for list selection is just the selector (no getter)
      final selector = cssRule.split('@').first;
      final elements = _cssSelect(doc.documentElement!, selector);
      return elements
          .map((e) => RuleElement.fromDomElement(e, baseUrl: baseUrl))
          .toList();
    } catch (e) {
      Logger.log('Legado: CSS rule list failed: $e');
      return [];
    }
  }

  String _evalCssOnElement(RuleElement element, String cssRule) {
    try {
      final el = element.asDomElement;
      if (el == null) return '';

      final steps = cssRule.split('@');
      final selector = steps[0];
      final getter = steps.length > 1 ? steps[1] : 'text';

      final found = _cssSelectFirst(el, selector);
      if (found == null) return '';

      return _applyGetter(found, getter);
    } catch (e) {
      return '';
    }
  }

  // ============================================================
  // CSS WILDCARD * SUPPORT
  // pseudom doesn't support the * wildcard selector, so we handle
  // it via manual DOM traversal as a fallback.
  // ============================================================

  /// Check if a CSS selector contains the * wildcard
  bool _hasWildcard(String selector) {
    // Match standalone * not part of ** or pseudo-selector syntax
    return RegExp(r'(?<![a-zA-Z0-9_-])\*(?![a-zA-Z0-9_-])').hasMatch(selector);
  }

  /// Select elements using CSS selector with * wildcard support.
  /// Falls back to DOM traversal when pseudom can't handle *.
  List<dom.Element> _cssSelect(dom.Element root, String selector) {
    final fixedSelector = _fixSelector(selector);

    // If no wildcard, try pseudom directly
    if (!_hasWildcard(fixedSelector)) {
      try {
        _initPseudoSelector();
        return pseudom.parse(fixedSelector).select(root).whereType<dom.Element>().toList();
      } catch (e) {
        Logger.log('Legado: CSS select failed for "$fixedSelector": $e');
        return [];
      }
    }

    // Handle wildcard selectors via DOM traversal
    return _selectWithWildcard(root, fixedSelector);
  }

  /// Select first element using CSS selector with * wildcard support
  dom.Element? _cssSelectFirst(dom.Element root, String selector) {
    final results = _cssSelect(root, selector);
    return results.isNotEmpty ? results.first : null;
  }

  /// Handle wildcard CSS selectors that pseudom can't process
  List<dom.Element> _selectWithWildcard(dom.Element root, String selector) {
    // Case 1: selector is just "*" — all element descendants
    if (selector.trim() == '*') {
      return _getAllDescendants(root);
    }

    // Case 2: "context *" — all descendants of context elements
    final descendantMatch = RegExp(r'^(.+?)\s+\*\s*$').firstMatch(selector);
    if (descendantMatch != null) {
      final contextSelector = descendantMatch.group(1)!.trim();
      try {
        _initPseudoSelector();
        final contextElements = pseudom.parse(contextSelector).select(root).whereType<dom.Element>().toList();
        final result = <dom.Element>[];
        for (final el in contextElements) {
          result.addAll(_getAllDescendants(el));
        }
        return result;
      } catch (e) {
        Logger.log('Legado: wildcard context select failed for "$contextSelector": $e');
        return [];
      }
    }

    // Case 3: "context > *" — direct children of context elements
    final childMatch = RegExp(r'^(.+?)\s*>\s*\*\s*$').firstMatch(selector);
    if (childMatch != null) {
      final contextSelector = childMatch.group(1)!.trim();
      try {
        _initPseudoSelector();
        final contextElements = pseudom.parse(contextSelector).select(root).whereType<dom.Element>().toList();
        final result = <dom.Element>[];
        for (final el in contextElements) {
          result.addAll(el.children);
        }
        return result;
      } catch (e) {
        return [];
      }
    }

    // Case 4: Complex selector with embedded * (e.g., "div.class > * + p")
    // Best-effort: try replacing * with 'div' as a generic tag fallback
    try {
      final fallbackSelector = selector.replaceAll('*', 'div');
      _initPseudoSelector();
      return pseudom.parse(fallbackSelector).select(root).whereType<dom.Element>().toList();
    } catch (e) {
      Logger.log('Legado: wildcard fallback select failed for "$selector": $e');
      return [];
    }
  }

  /// Recursively collect all descendant elements
  List<dom.Element> _getAllDescendants(dom.Element root) {
    final result = <dom.Element>[];
    void collect(dom.Element element) {
      for (final child in element.children) {
        result.add(child);
        collect(child);
      }
    }
    collect(root);
    return result;
  }

  // ============================================================
  // XPATH RULE ENGINE
  // ============================================================

  String _evalXPathRule(String content, String xpathRule) {
    try {
      final doc = html_parser.parse(content);
      final htmlXPath = HtmlXPath.node(doc.documentElement!);
      final query = htmlXPath.query(xpathRule);
      return query.attr ?? '';
    } catch (e) {
      Logger.log('Legado: XPath rule failed: $e');
      return '';
    }
  }

  List<RuleElement> _evalXPathRuleList(String content, String xpathRule) {
    try {
      final doc = html_parser.parse(content);
      final htmlXPath = HtmlXPath.node(doc.documentElement!);
      final query = htmlXPath.query(xpathRule);
      return query.nodes
          .whereType<dom.Element>()
          .map((e) => RuleElement.fromDomElement(e, baseUrl: baseUrl))
          .toList();
    } catch (e) {
      Logger.log('Legado: XPath rule list failed: $e');
      return [];
    }
  }

  String _evalXPathOnElement(RuleElement element, String xpathRule) {
    try {
      final el = element.asDomElement;
      if (el == null) return '';
      final htmlXPath = HtmlXPath.node(el);
      final query = htmlXPath.query(xpathRule);
      return query.attr ?? '';
    } catch (e) {
      return '';
    }
  }

  // ============================================================
  // JSONPATH RULE ENGINE
  // ============================================================

  String _evalJsonPathRule(String content, String jsonPath) {
    try {
      dynamic data;
      try {
        data = jsonDecode(content);
      } catch (_) {
        return '';
      }
      final result = _evaluateJsonPath(data, jsonPath);
      if (result is List && result.isNotEmpty) {
        return result.first?.toString() ?? '';
      }
      return result?.toString() ?? '';
    } catch (e) {
      Logger.log('Legado: JSONPath rule failed: $e');
      return '';
    }
  }

  List<RuleElement> _evalJsonPathRuleList(String content, String jsonPath) {
    try {
      dynamic data;
      try {
        data = jsonDecode(content);
      } catch (_) {
        return [];
      }
      final result = _evaluateJsonPath(data, jsonPath);
      if (result is List) {
        return result.map((item) {
          if (item is Map<String, dynamic>) {
            return RuleElement.fromJson(item, baseUrl: baseUrl);
          }
          return RuleElement.fromString(item.toString(), baseUrl: baseUrl);
        }).toList();
      }
      return [];
    } catch (e) {
      Logger.log('Legado: JSONPath rule list failed: $e');
      return [];
    }
  }

  String _evalJsonPathOnElement(RuleElement element, String jsonPath) {
    try {
      if (element.jsonData == null) return '';
      final result = _evaluateJsonPath(element.jsonData!, jsonPath);
      if (result is List && result.isNotEmpty) {
        return result.first?.toString() ?? '';
      }
      return result?.toString() ?? '';
    } catch (e) {
      return '';
    }
  }

  /// Simple JSONPath evaluator
  /// Supports: $, .key, [index], [*], ..key (recursive descent)
  dynamic _evaluateJsonPath(dynamic data, String path) {
    var current = data;
    final tokens = _tokenizeJsonPath(path);

    for (final token in tokens) {
      if (current == null) return null;

      if (token == '\$') continue;

      if (token.startsWith('[') && token.endsWith(']')) {
        final indexStr = token.substring(1, token.length - 1);
        if (indexStr == '*') {
          if (current is List) {
            // Return all items flattened
            final results = <dynamic>[];
            for (final item in current) {
              results.add(item);
            }
            return results;
          }
        } else {
          final index = int.tryParse(indexStr);
          if (index != null && current is List && index < current.length) {
            current = current[index];
          } else {
            return null;
          }
        }
      } else if (token == '..') {
        // Recursive descent is handled specially
        continue;
      } else if (token.startsWith('..')) {
        // Recursive descent with key
        final key = token.substring(2);
        return _recursiveSearch(current, key);
      } else {
        // Object key access
        if (current is Map) {
          current = current[token];
        } else if (current is List) {
          // Try to access this key on each element
          final results = <dynamic>[];
          for (final item in current) {
            if (item is Map && item.containsKey(token)) {
              results.add(item[token]);
            }
          }
          if (results.length == 1) {
            current = results.first;
          } else {
            current = results;
          }
        } else {
          return null;
        }
      }
    }

    return current;
  }

  List<String> _tokenizeJsonPath(String path) {
    final tokens = <String>[];
    var current = StringBuffer();

    for (int i = 0; i < path.length; i++) {
      if (path[i] == '.') {
        // Check for recursive descent first
        if (i + 1 < path.length && path[i + 1] == '.') {
          if (current.isNotEmpty) {
            tokens.add(current.toString());
            current = StringBuffer();
          }
          tokens.add('..');
          i++; // Skip next dot
          continue;
        }
        // Dot is a separator - flush current token
        if (current.isNotEmpty) {
          tokens.add(current.toString());
          current = StringBuffer();
        }
        // Skip the dot itself (it's just a separator)
      } else if (path[i] == '[') {
        if (current.isNotEmpty) {
          tokens.add(current.toString());
          current = StringBuffer();
        }
        final end = path.indexOf(']', i);
        if (end != -1) {
          tokens.add(path.substring(i, end + 1));
          i = end;
        }
      } else if (path[i] == '\$') {
        if (current.isNotEmpty) {
          tokens.add(current.toString());
          current = StringBuffer();
        }
        tokens.add('\$');
      } else {
        current.write(path[i]);
      }
    }
    if (current.isNotEmpty) tokens.add(current.toString());

    return tokens;
  }

  dynamic _recursiveSearch(dynamic data, String key) {
    final results = <dynamic>[];
    _recursiveSearchHelper(data, key, results);
    if (results.length == 1) return results.first;
    return results;
  }

  void _recursiveSearchHelper(dynamic data, String key, List<dynamic> results) {
    if (data is Map) {
      if (data.containsKey(key)) {
        results.add(data[key]);
      }
      for (final value in data.values) {
        _recursiveSearchHelper(value, key, results);
      }
    } else if (data is List) {
      for (final item in data) {
        _recursiveSearchHelper(item, key, results);
      }
    }
  }

  // ============================================================
  // JAVASCRIPT RULE ENGINE
  // ============================================================

  Future<String> _evalJsRule(
    String jsCode,
    String content, {
    String? baseUrlOverride,
    Map<String, dynamic>? extraContext,
  }) async {
    JavascriptRuntime? runtime;
    try {
      runtime = QuickJsRuntime2(stackSize: 1024 * 1024 * 4);
      runtime.enableHandlePromises();

      // Inject bridge globals
      final bridgeCode = '''
        var baseUrl = "${baseUrlOverride ?? baseUrl}";
        var result = ${jsonEncode(content)};
        var book = {};
        var source = {};
        var java = {
          ajax: function(url) { return _javaAjax(url); },
          getStrResponse: function(url) { return _javaAjax(url); },
          connect: function(url) { return _javaAjax(url); },
          base64Decode: function(str) { return _base64Decode(str); },
          base64Encode: function(str) { return _base64Encode(str); },
          md5Encode: function(str) { return str; },
          hexDecodeToString: function(str) { return str; },
          log: function(msg) { console.log(msg); },
        };
        var cookie = {
          getCookie: function(url, key) { return ""; },
          setCookie: function(url, key, value) {},
        };
      ''';

      runtime.evaluate(bridgeCode);

      // Inject helper functions
      runtime.evaluate('''
        function _javaAjax(url) {
          return ""; // Sync ajax not supported, use async
        }
        function _base64Decode(str) {
          try { return atob(str); } catch(e) { return str; }
        }
        function _base64Encode(str) {
          try { return btoa(str); } catch(e) { return str; }
        }
      ''');

      // Inject extra context
      if (extraContext != null) {
        for (final entry in extraContext.entries) {
          runtime.evaluate('var ${entry.key} = ${jsonEncode(entry.value)};');
        }
      }

      // Execute JS code
      final wrappedCode = '''
        (function() {
          try {
            $jsCode
          } catch(e) {
            return "";
          }
        })()
      ''';

      final result = runtime.evaluate(wrappedCode);
      return result.stringResult;
    } catch (e) {
      Logger.log('Legado: JS rule failed: $e');
      return '';
    } finally {
      runtime?.dispose();
    }
  }

  // ============================================================
  // UTILITY METHODS
  // ============================================================

  /// Split rule by operator, respecting nested structures
  List<String> _splitOperators(String rule, String op) {
    final parts = <String>[];
    var depth = 0;
    var current = StringBuffer();
    var i = 0;

    while (i < rule.length) {
      // Track nesting depth
      if (rule[i] == '(' || rule[i] == '[' || rule[i] == '{') depth++;
      if (rule[i] == ')' || rule[i] == ']' || rule[i] == '}') depth--;

      // Check for operator
      if (depth == 0 && rule.substring(i).startsWith(op)) {
        parts.add(current.toString());
        current = StringBuffer();
        i += op.length;
        continue;
      }

      current.write(rule[i]);
      i++;
    }
    if (current.isNotEmpty) parts.add(current.toString());

    return parts;
  }

  /// Pseudo-selector initialization (from Mangayomi's dom_extensions)
  static bool _pseudoInitialized = false;

  void _initPseudoSelector() {
    if (_pseudoInitialized) return;
    _pseudoInitialized = true;

    // Register common pseudo-selector handlers
    pseudom.PseudoSelector.handlers['nth-child'] = (dom.Element element, String? args) {
      final parent = element.parent;
      if (parent == null) return false;
      final index = parent.children.indexOf(element) + 1;
      final n = int.tryParse(args ?? '');
      return n != null && index == n;
    };
    pseudom.PseudoSelector.handlers['first-child'] = (dom.Element element, String? args) {
      return element.previousElementSibling == null;
    };
    pseudom.PseudoSelector.handlers['last-child'] = (dom.Element element, String? args) {
      return element.nextElementSibling == null;
    };
  }

  String _fixSelector(String selector) {
    return selector.replaceAll(':not', ':inot');
  }

  // ============================================================
  // JS SEARCH URL RESOLUTION
  // Some Legado sources use @js: in their searchUrl field
  // to dynamically construct the search URL via JavaScript.
  // ============================================================

  /// Evaluate a @js: prefixed searchUrl to produce the actual search URL.
  /// The JS code has access to: key, page, baseUrl, source
  /// Returns a ResolvedUrl with the constructed URL.
  Future<ResolvedUrl> resolveJsSearchUrl(
    String jsCode, {
    String? key,
    int? page,
  }) async {
    final result = await _evalJsRule(
      jsCode,
      '', // No page content for searchUrl construction
      extraContext: {
        'key': key ?? '',
        'page': page ?? 1,
      },
    );

    if (result.isEmpty) {
      return ResolvedUrl(url: '');
    }

    // The JS result might be just a URL, or URL + POST config
    // Pass through resolveUrlTemplate to handle any remaining template vars or POST config
    return resolveUrlTemplate(result, key: key, page: page);
  }
}

// ============================================================
// SUPPORTING TYPES
// ============================================================

/// Represents a resolved URL with method, body, and headers
class ResolvedUrl {
  final String url;
  final String method;
  final String? body;
  final Map<String, String> headers;
  final String? charset;

  ResolvedUrl({
    required this.url,
    this.method = 'GET',
    this.body,
    this.headers = const {},
    this.charset,
  });
}

/// Represents an element matched by a rule - can be HTML or JSON
class RuleElement {
  final String htmlContent;
  final Map<String, dynamic>? jsonData;
  final String? textContent;
  final String baseUrl;
  final Map<String, String>? attributes;

  RuleElement({
    required this.htmlContent,
    this.jsonData,
    this.textContent,
    required this.baseUrl,
    this.attributes,
  });

  factory RuleElement.fromDomElement(dom.Element element, {String baseUrl = ''}) {
    return RuleElement(
      htmlContent: element.outerHtml,
      textContent: element.text.trim(),
      baseUrl: baseUrl,
      attributes: Map<String, String>.from(element.attributes),
    );
  }

  factory RuleElement.fromJson(Map<String, dynamic> json, {String baseUrl = ''}) {
    return RuleElement(
      htmlContent: jsonEncode(json),
      jsonData: json,
      textContent: jsonEncode(json),
      baseUrl: baseUrl,
    );
  }

  factory RuleElement.fromString(String text, {String baseUrl = ''}) {
    return RuleElement(
      htmlContent: text,
      textContent: text,
      baseUrl: baseUrl,
    );
  }

  dom.Element? get asDomElement {
    try {
      final doc = html_parser.parse(htmlContent);
      final body = doc.body;
      if (body != null && body.children.isNotEmpty) {
        return body.children.first;
      }
      return doc.documentElement;
    } catch (e) {
      return null;
    }
  }

  String? getAttribute(String name) {
    if (attributes != null && attributes!.containsKey(name)) {
      final val = attributes![name] ?? '';
      if ((name == 'href' || name == 'src') && val.isNotEmpty) {
        if (val.startsWith('/')) {
          final base = Uri.parse(baseUrl);
          return '${base.scheme}://${base.host}$val';
        }
      }
      return val;
    }
    return null;
  }
}
