#target aftereffects

(function () {
    function nowIso() {
        return new Date().toUTCString();
    }

    // ---------------------------------------------------------------- files
    // Both helpers close the handle in finally, so a read or write that throws
    // half-way does not leave the file open in the host application.

    function readText(path) {
        var file = File(path);
        file.encoding = 'UTF-8';
        if (!file.open('r')) {
            throw new Error('Could not open for read: ' + path);
        }
        try {
            return file.read();
        }
        finally {
            file.close();
        }
    }

    function writeText(path, text) {
        var file = File(path);
        file.encoding = 'UTF-8';
        if (!file.open('w')) {
            throw new Error('Could not open for write: ' + path);
        }
        try {
            file.write(text);
        }
        finally {
            file.close();
        }
    }

    // ----------------------------------------------------------------- JSON
    // The config file comes from the runner, but it is still data, and data is
    // never executed. ExtendScript has no JSON object of its own, so when the host
    // does not provide one the text goes through a strict recursive-descent parser
    // that accepts JSON and nothing else.

    function parseJson(text) {
        if (typeof JSON !== 'undefined' && JSON.parse) {
            return JSON.parse(text);
        }
        return parseJsonStrict(text);
    }

    function parseJsonStrict(text) {
        var source = String(text);
        var pos = 0;

        function fail(message) {
            throw new Error('Invalid JSON at offset ' + pos + ': ' + message);
        }

        function skipWhitespace() {
            while (pos < source.length) {
                var ch = source.charAt(pos);
                if (ch === ' ' || ch === '\t' || ch === '\r' || ch === '\n') {
                    pos++;
                }
                else {
                    break;
                }
            }
        }

        function expectLiteral(word, value) {
            if (source.substr(pos, word.length) !== word) {
                fail('expected ' + word);
            }
            pos += word.length;
            return value;
        }

        function parseString() {
            if (source.charAt(pos) !== '"') {
                fail('expected string');
            }
            pos++;
            var out = '';
            while (pos < source.length) {
                var ch = source.charAt(pos++);
                if (ch === '"') {
                    return out;
                }
                if (ch === '\\') {
                    var esc = source.charAt(pos++);
                    if (esc === '"' || esc === '\\' || esc === '/') {
                        out += esc;
                    }
                    else if (esc === 'b') {
                        out += '\b';
                    }
                    else if (esc === 'f') {
                        out += '\f';
                    }
                    else if (esc === 'n') {
                        out += '\n';
                    }
                    else if (esc === 'r') {
                        out += '\r';
                    }
                    else if (esc === 't') {
                        out += '\t';
                    }
                    else if (esc === 'u') {
                        var hex = source.substr(pos, 4);
                        if (!/^[0-9a-fA-F]{4}$/.test(hex)) {
                            fail('bad unicode escape');
                        }
                        out += String.fromCharCode(parseInt(hex, 16));
                        pos += 4;
                    }
                    else {
                        fail('bad escape');
                    }
                }
                else if (ch.charCodeAt(0) < 32) {
                    fail('control character in string');
                }
                else {
                    out += ch;
                }
            }
            fail('unterminated string');
        }

        function parseNumber() {
            var match = /^-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?/.exec(source.substr(pos));
            if (!match) {
                fail('expected number');
            }
            pos += match[0].length;
            return Number(match[0]);
        }

        function parseArray() {
            pos++;
            var items = [];
            skipWhitespace();
            if (source.charAt(pos) === ']') {
                pos++;
                return items;
            }
            while (true) {
                skipWhitespace();
                items.push(parseValue());
                skipWhitespace();
                var ch = source.charAt(pos++);
                if (ch === ']') {
                    return items;
                }
                if (ch !== ',') {
                    fail('expected , or ]');
                }
            }
        }

        function parseObject() {
            pos++;
            var obj = {};
            skipWhitespace();
            if (source.charAt(pos) === '}') {
                pos++;
                return obj;
            }
            while (true) {
                skipWhitespace();
                var key = parseString();
                skipWhitespace();
                if (source.charAt(pos++) !== ':') {
                    fail('expected :');
                }
                skipWhitespace();
                obj[key] = parseValue();
                skipWhitespace();
                var ch = source.charAt(pos++);
                if (ch === '}') {
                    return obj;
                }
                if (ch !== ',') {
                    fail('expected , or }');
                }
            }
        }

        function parseValue() {
            skipWhitespace();
            var ch = source.charAt(pos);
            if (ch === '{') {
                return parseObject();
            }
            if (ch === '[') {
                return parseArray();
            }
            if (ch === '"') {
                return parseString();
            }
            if (ch === 't') {
                return expectLiteral('true', true);
            }
            if (ch === 'f') {
                return expectLiteral('false', false);
            }
            if (ch === 'n') {
                return expectLiteral('null', null);
            }
            if (ch === '-' || (ch >= '0' && ch <= '9')) {
                return parseNumber();
            }
            fail('unexpected character ' + ch);
        }

        var value = parseValue();
        skipWhitespace();
        if (pos !== source.length) {
            fail('trailing characters');
        }
        return value;
    }

    function quoteJsonString(value) {
        var s = String(value);
        s = s.replace(/\\/g, '\\\\');
        s = s.replace(/"/g, '\\"');
        s = s.replace(/\r/g, '\\r');
        s = s.replace(/\n/g, '\\n');
        s = s.replace(/\t/g, '\\t');
        return '"' + s + '"';
    }

    function toJson(value) {
        if (value === null || value === undefined) {
            return 'null';
        }
        var type = typeof value;
        if (type === 'string') {
            return quoteJsonString(value);
        }
        if (type === 'number') {
            return isFinite(value) ? String(value) : 'null';
        }
        if (type === 'boolean') {
            return value ? 'true' : 'false';
        }
        if (value instanceof Array) {
            var arrayParts = [];
            for (var i = 0; i < value.length; i++) {
                arrayParts.push(toJson(value[i]));
            }
            return '[' + arrayParts.join(',') + ']';
        }
        var parts = [];
        for (var key in value) {
            if (value.hasOwnProperty(key)) {
                parts.push(quoteJsonString(key) + ':' + toJson(value[key]));
            }
        }
        return '{' + parts.join(',') + '}';
    }

    // ------------------------------------------------------------ redaction
    // The inventory is meant to be handed around. What it must not carry is the
    // content of text layers (scripts, names, anything a template's author typed)
    // or absolute paths from the machine that holds the footage. Each is reduced to
    // something that still identifies it — a length, a shape, a file name, and a
    // short hash for matching — without reproducing it.

    function hashString(value) {
        // FNV-1a, 32-bit, as hex. Not cryptographic; it only has to let two records
        // that refer to the same thing be matched up.
        var s = String(value === null || value === undefined ? '' : value);
        var hash = 0x811c9dc5;
        for (var i = 0; i < s.length; i++) {
            hash ^= s.charCodeAt(i);
            hash += (hash << 1) + (hash << 4) + (hash << 7) + (hash << 8) + (hash << 24);
            hash >>>= 0;
        }
        return ('00000000' + hash.toString(16)).slice(-8);
    }

    function redactText(value) {
        if (value === null || value === undefined) {
            return { textLength: null, textHash: null, textShape: null };
        }
        var s = String(value);
        // keep whitespace so line and word structure survives, mask everything else
        var shape = s.replace(/[^\s]/g, '*');
        return {
            textLength: s.length,
            textHash: hashString(s),
            textShape: shape.length > 80 ? shape.substr(0, 80) + '...' : shape
        };
    }

    function baseName(path) {
        if (!path) {
            return null;
        }
        var s = String(path).replace(/\\/g, '/');
        var idx = s.lastIndexOf('/');
        return idx >= 0 ? s.substr(idx + 1) : s;
    }

    function redactPath(path) {
        if (!path) {
            return { fileName: null, filePathHash: null };
        }
        return {
            fileName: baseName(path),
            filePathHash: hashString(path)
        };
    }

    function normalizePathForCompare(path) {
        return String(path || '').replace(/\\/g, '/').replace(/\/+$/, '').toLowerCase();
    }

    function roundNumber(value, places) {
        if (typeof value !== 'number' || !isFinite(value)) {
            return null;
        }
        var scale = Math.pow(10, places || 3);
        return Math.round(value * scale) / scale;
    }

    function safeName(value) {
        try {
            return value ? String(value) : '';
        }
        catch (err) {
            return '';
        }
    }

    function getItemType(item) {
        if (item instanceof CompItem) {
            return 'CompItem';
        }
        if (item instanceof FootageItem) {
            return 'FootageItem';
        }
        if (item instanceof FolderItem) {
            return 'FolderItem';
        }
        return 'Item';
    }

    function getSourceKind(source) {
        if (!source) {
            return null;
        }
        if (source instanceof CompItem) {
            return 'CompItem';
        }
        if (source instanceof FootageItem) {
            try {
                if (source.mainSource instanceof PlaceholderSource) {
                    return 'PlaceholderSource';
                }
                if (source.mainSource instanceof SolidSource) {
                    return 'SolidSource';
                }
                if (source.mainSource instanceof FileSource) {
                    return 'FileSource';
                }
            }
            catch (err) {
                return 'FootageItem';
            }
            return 'FootageItem';
        }
        return getItemType(source);
    }

    function getFilePath(footage) {
        try {
            if (footage && footage.file) {
                return footage.file.fsName;
            }
        }
        catch (err) {
        }
        return null;
    }

    function getParentFolderName(item) {
        try {
            if (item.parentFolder) {
                return item.parentFolder.name;
            }
        }
        catch (err) {
        }
        return null;
    }

    function hasNameToken(name, tokens) {
        var lower = String(name || '').toLowerCase();
        for (var i = 0; i < tokens.length; i++) {
            if (lower.indexOf(tokens[i]) >= 0) {
                return true;
            }
        }
        return false;
    }

    function mediaSlotReason(compName, layerName, sourceName, sourceKind, missing) {
        var text = [compName, layerName, sourceName].join(' ').toLowerCase();
        var tokens = [
            'media', 'placeholder', 'replace', 'footage', 'image', 'video',
            'photo', 'picture', 'logo', 'drop', 'slot', 'pic', 'insert'
        ];
        var reasons = [];
        for (var i = 0; i < tokens.length; i++) {
            if (text.indexOf(tokens[i]) >= 0) {
                reasons.push('name_contains_' + tokens[i]);
            }
        }
        if (sourceKind === 'PlaceholderSource') {
            reasons.push('placeholder_source');
        }
        if (sourceKind === 'FileSource') {
            reasons.push('file_source');
        }
        if (missing) {
            reasons.push('missing_footage');
        }
        return reasons;
    }

    function readTextLayer(layer) {
        var result = null;
        try {
            var prop = layer.property('Source Text');
            if (!prop) {
                return null;
            }
            var doc = prop.value;
            result = {
                text: doc && doc.text !== undefined ? String(doc.text) : '',
                font: doc && doc.font !== undefined ? String(doc.font) : null,
                fontSize: doc && doc.fontSize !== undefined ? roundNumber(doc.fontSize, 3) : null
            };
        }
        catch (err) {
            result = {
                text: null,
                font: null,
                fontSize: null,
                error: String(err)
            };
        }
        return result;
    }

    function getLayerSource(layer) {
        try {
            if (layer.source) {
                return layer.source;
            }
        }
        catch (err) {
        }
        return null;
    }

    // ------------------------------------------------------- layer details
    // Per-layer records are the bulk of a large project's output. They are only
    // collected when the runner asks for them (includeLayerDetails), and then only
    // up to a per-comp ceiling (maxLayersPerComp); everything past the ceiling is
    // counted, not stored.

    function getMaxLayers(parseConfig) {
        var value = parseConfig ? Number(parseConfig.maxLayersPerComp) : NaN;
        if (!isFinite(value) || value < 1) {
            return 200;
        }
        return Math.floor(value);
    }

    function recordLayerDetail(target, layerInfo, limits) {
        if (!limits.includeLayerDetails) {
            target.layerDetailsOmitted += 1;
            return;
        }
        if (target.layers.length >= limits.maxLayers) {
            target.layerDetailsOmitted += 1;
            return;
        }
        target.layers.push(layerInfo);
    }

    function scanCompLayers(comp, templateResult, compInfo, nestedByCompId, limits) {
        for (var layerIndex = 1; layerIndex <= comp.numLayers; layerIndex++) {
            var layer = comp.layer(layerIndex);
            var source = getLayerSource(layer);
            var sourceKind = getSourceKind(source);
            var sourcePath = source instanceof FootageItem ? getFilePath(source) : null;
            var sourceRedacted = redactPath(sourcePath);
            var missing = false;
            try {
                missing = !!(source instanceof FootageItem && source.footageMissing);
            }
            catch (err) {
            }

            var layerInfo = {
                index: layerIndex,
                name: safeName(layer.name),
                enabled: !!layer.enabled,
                locked: !!layer.locked,
                shy: !!layer.shy,
                solo: !!layer.solo,
                hasVideo: !!layer.hasVideo,
                hasAudio: !!layer.hasAudio,
                startTime: roundNumber(layer.startTime, 3),
                inPoint: roundNumber(layer.inPoint, 3),
                outPoint: roundNumber(layer.outPoint, 3),
                stretch: roundNumber(layer.stretch, 3),
                sourceName: source ? safeName(source.name) : null,
                sourceKind: sourceKind,
                sourceFileName: sourceRedacted.fileName,
                sourcePathHash: sourceRedacted.filePathHash
            };
            recordLayerDetail(compInfo, layerInfo, limits);

            var textInfo = readTextLayer(layer);
            if (textInfo) {
                var textRedacted = redactText(textInfo.text);
                templateResult.textLayers.push({
                    compName: comp.name,
                    layerIndex: layerIndex,
                    layerName: safeName(layer.name),
                    textLength: textRedacted.textLength,
                    textHash: textRedacted.textHash,
                    textShape: textRedacted.textShape,
                    font: textInfo.font,
                    fontSize: textInfo.fontSize,
                    error: textInfo.error || null
                });
            }

            if (source instanceof CompItem) {
                templateResult.nestedCompLinks.push({
                    parentComp: comp.name,
                    layerIndex: layerIndex,
                    layerName: safeName(layer.name),
                    childComp: source.name,
                    childCompId: source.id || null,
                    inPoint: roundNumber(layer.inPoint, 3),
                    outPoint: roundNumber(layer.outPoint, 3)
                });
                nestedByCompId[String(source.id || source.name)] = true;
            }

            if (source instanceof FootageItem) {
                var reasons = mediaSlotReason(comp.name, layer.name, source.name, sourceKind, missing);
                if (reasons.length > 0) {
                    templateResult.mediaSlots.push({
                        compName: comp.name,
                        layerIndex: layerIndex,
                        layerName: safeName(layer.name),
                        sourceName: safeName(source.name),
                        sourceKind: sourceKind,
                        sourceFileName: sourceRedacted.fileName,
                        sourcePathHash: sourceRedacted.filePathHash,
                        missing: missing,
                        inPoint: roundNumber(layer.inPoint, 3),
                        outPoint: roundNumber(layer.outPoint, 3),
                        reasons: reasons
                    });
                }
            }
        }
    }

    function scoreRenderComp(compInfo, isNested) {
        var score = 0;
        var reasons = [];
        var name = String(compInfo.name || '').toLowerCase();
        var strongNames = ['render', 'final', 'main', 'output', 'master', 'montage', 'preview'];
        for (var i = 0; i < strongNames.length; i++) {
            if (name.indexOf(strongNames[i]) >= 0) {
                score += 5;
                reasons.push('name_contains_' + strongNames[i]);
            }
        }
        if (!isNested) {
            score += 3;
            reasons.push('not_nested_in_other_comp');
        }
        if (compInfo.width >= 1280 && compInfo.height >= 720) {
            score += 2;
            reasons.push('hd_or_larger');
        }
        if (compInfo.durationSeconds && compInfo.durationSeconds >= 5) {
            score += 1;
            reasons.push('duration_at_least_5s');
        }
        if (compInfo.layerCount && compInfo.layerCount >= 3) {
            score += 1;
            reasons.push('has_multiple_layers');
        }
        return {
            name: compInfo.name,
            width: compInfo.width,
            height: compInfo.height,
            frameRate: compInfo.frameRate,
            durationSeconds: compInfo.durationSeconds,
            layerCount: compInfo.layerCount,
            score: score,
            reasons: reasons
        };
    }

    function templateIdentity(templateConfig) {
        // What the runner already reduced the template's own path to: a path relative
        // to the material root, the file name, and a hash of the absolute path. The
        // absolute path itself never reaches this script.
        return {
            index: templateConfig.index,
            name: templateConfig.name,
            sourceRelativePath: templateConfig.sourceRelativePath || null,
            sourceFileName: templateConfig.sourceFileName || baseName(templateConfig.sourceRelativePath),
            sourcePathHash: templateConfig.sourcePathHash || null,
            workingCopyName: baseName(templateConfig.workingCopyPath),
            lengthBytes: templateConfig.lengthBytes,
            lastWriteTime: templateConfig.lastWriteTime
        };
    }

    function scanProject(templateConfig, limits) {
        var identity = templateIdentity(templateConfig);
        var result = {
            index: identity.index,
            name: identity.name,
            sourceRelativePath: identity.sourceRelativePath,
            sourceFileName: identity.sourceFileName,
            sourcePathHash: identity.sourcePathHash,
            workingCopyName: identity.workingCopyName,
            lengthBytes: identity.lengthBytes,
            lastWriteTime: identity.lastWriteTime,
            status: 'started',
            project: {},
            comps: [],
            footages: [],
            folders: [],
            mediaSlots: [],
            textLayers: [],
            nestedCompLinks: [],
            possibleRenderComps: [],
            summary: {}
        };

        var projectFile = File(templateConfig.workingCopyPath);
        if (!projectFile.exists) {
            throw new Error('Working copy does not exist: ' + templateConfig.workingCopyPath);
        }

        app.open(projectFile);
        try {
            var project = app.project;
            var nestedByCompId = {};

            result.project = {
                fileName: project.file ? project.file.name : null,
                numItems: project.numItems,
                bitsPerChannel: project.bitsPerChannel,
                workingSpace: project.workingSpace || null,
                linearBlending: !!project.linearBlending
            };

            for (var i = 1; i <= project.numItems; i++) {
                var item = project.item(i);
                if (item instanceof FolderItem) {
                    result.folders.push({
                        name: item.name,
                        parentFolder: getParentFolderName(item),
                        numItems: item.numItems
                    });
                }
                else if (item instanceof FootageItem) {
                    var sourceKind = getSourceKind(item);
                    var fileRedacted = redactPath(getFilePath(item));
                    var footageMissing = false;
                    try {
                        footageMissing = !!item.footageMissing;
                    }
                    catch (err) {
                    }
                    result.footages.push({
                        name: item.name,
                        parentFolder: getParentFolderName(item),
                        width: item.width || null,
                        height: item.height || null,
                        durationSeconds: roundNumber(item.duration, 3),
                        frameRate: roundNumber(item.frameRate, 3),
                        hasVideo: !!item.hasVideo,
                        hasAudio: !!item.hasAudio,
                        sourceKind: sourceKind,
                        fileName: fileRedacted.fileName,
                        filePathHash: fileRedacted.filePathHash,
                        missing: footageMissing
                    });
                }
                else if (item instanceof CompItem) {
                    var compInfo = {
                        id: item.id || null,
                        name: item.name,
                        parentFolder: getParentFolderName(item),
                        width: item.width,
                        height: item.height,
                        pixelAspect: roundNumber(item.pixelAspect, 5),
                        frameRate: roundNumber(item.frameRate, 3),
                        durationSeconds: roundNumber(item.duration, 3),
                        workAreaStart: roundNumber(item.workAreaStart, 3),
                        workAreaDuration: roundNumber(item.workAreaDuration, 3),
                        layerCount: item.numLayers,
                        layers: [],
                        layerDetailsOmitted: 0
                    };
                    scanCompLayers(item, result, compInfo, nestedByCompId, limits);
                    result.comps.push(compInfo);
                }
            }

            var candidates = [];
            for (var c = 0; c < result.comps.length; c++) {
                var comp = result.comps[c];
                var key = String(comp.id || comp.name);
                candidates.push(scoreRenderComp(comp, !!nestedByCompId[key]));
            }
            candidates.sort(function (a, b) {
                if (b.score !== a.score) {
                    return b.score - a.score;
                }
                return String(a.name).toLowerCase() < String(b.name).toLowerCase() ? -1 : 1;
            });
            result.possibleRenderComps = candidates.slice(0, 10);
            result.summary = {
                compCount: result.comps.length,
                footageCount: result.footages.length,
                folderCount: result.folders.length,
                textLayerCount: result.textLayers.length,
                mediaSlotCount: result.mediaSlots.length,
                nestedCompLinkCount: result.nestedCompLinks.length,
                possibleRenderCompCount: result.possibleRenderComps.length,
                layerDetailsIncluded: !!limits.includeLayerDetails
            };
            result.status = 'parsed';
        }
        finally {
            // Whatever happened above, the working copy is closed without saving.
            app.project.close(CloseOptions.DO_NOT_SAVE_CHANGES);
        }
        return result;
    }

    function summarizeTemplate(result, detailFileName) {
        // What goes into the batch output: the identity, the counts and the ranked
        // comps. The full per-comp detail lives in its own file, written as soon as
        // the template is parsed, so the batch never holds every project in memory.
        return {
            index: result.index,
            name: result.name,
            sourceRelativePath: result.sourceRelativePath,
            sourceFileName: result.sourceFileName,
            sourcePathHash: result.sourcePathHash,
            workingCopyName: result.workingCopyName,
            lengthBytes: result.lengthBytes,
            lastWriteTime: result.lastWriteTime,
            status: result.status,
            summary: result.summary,
            possibleRenderComps: result.possibleRenderComps,
            detailFile: detailFileName
        };
    }

    function sanitizeFileName(value) {
        return String(value || 'template').replace(/[^A-Za-z0-9._-]/g, '_');
    }

    function zeroPad(value, width) {
        var s = String(value);
        while (s.length < width) {
            s = '0' + s;
        }
        return s;
    }

    function releaseHostApplication(parseConfig) {
        // Quit only an After Effects the runner launched for this scan. When the
        // runner was told to reuse a session that was already open (allowExistingAE),
        // that session belongs to a person and is left exactly as it was.
        if (parseConfig && parseConfig.allowExistingAE) {
            return;
        }
        try {
            app.quit()
        }
        catch (quitErr) {
        }
    }

    // ---------------------------------------------------------------- main

    var configPath = $.global.AE_TEMPLATE_PARSE_CONFIG;
    if (!configPath) {
        throw new Error('AE_TEMPLATE_PARSE_CONFIG was not set by the runner wrapper.');
    }

    var config = parseJson(readText(configPath));

    // Every path the runner asks this script to write must sit inside the run
    // directory the runner created for this scan, and must be a .json file. A
    // config that points anywhere else is rejected before a single byte is written,
    // so a tampered or mis-generated config cannot turn the parser into a way of
    // writing arbitrary files.
    if (!config.runDir) {
        throw new Error('config.runDir is required.');
    }
    var runDirFolder = Folder(config.runDir);
    if (!runDirFolder.exists) {
        throw new Error('config.runDir does not exist: ' + config.runDir);
    }
    var runDirPrefix = normalizePathForCompare(runDirFolder.fsName) + '/';

    var requireJsonInsideRunDir = function (label, value) {
        if (!value) {
            throw new Error('config.' + label + ' is required.');
        }
        var target = normalizePathForCompare(File(value).fsName);
        if (target.indexOf(runDirPrefix) !== 0) {
            throw new Error('config.' + label + ' must be inside config.runDir.');
        }
        if (!/\.json$/i.test(target)) {
            throw new Error('config.' + label + ' must be a .json file.');
        }
        return value;
    };

    var requireFolderInsideRunDir = function (label, value) {
        if (!value) {
            throw new Error('config.' + label + ' is required.');
        }
        var target = normalizePathForCompare(Folder(value).fsName);
        if (target.indexOf(runDirPrefix) !== 0) {
            throw new Error('config.' + label + ' must be inside config.runDir.');
        }
        return value;
    };

    var outputJsonPath = requireJsonInsideRunDir('outputJsonPath', config.outputJsonPath);
    var statusJsonPath = requireJsonInsideRunDir('statusJsonPath', config.statusJsonPath);
    var templatesDir = requireFolderInsideRunDir('templatesDir', config.templatesDir);
    var templatesFolder = Folder(templatesDir);
    if (!templatesFolder.exists && !templatesFolder.create()) {
        throw new Error('Could not create config.templatesDir: ' + templatesDir);
    }

    var limits = {
        includeLayerDetails: !!config.includeLayerDetails,
        maxLayers: getMaxLayers(config)
    };

    var output = {
        schemaVersion: 2,
        generatedAt: nowIso(),
        materialRoot: config.materialRoot,
        runDir: config.runDir,
        templatesDir: templatesDir,
        redaction: 'Text layer contents are reduced to length, hash and shape; footage paths to file name and hash; template paths are relative to materialRoot. No text content and no absolute media path is written.',
        templates: []
    };

    try {
        app.beginSuppressDialogs();
        for (var i = 0; i < config.templates.length; i++) {
            var templateConfig = config.templates[i];
            try {
                var templateResult = scanProject(templateConfig, limits);
                var templateDetailName = zeroPad(templateConfig.index, 3) + '_' + sanitizeFileName(templateConfig.name) + '.json';
                var templateDetailPath = templatesFolder.fsName + '/' + templateDetailName;
                // stream: one file per template, written the moment it is parsed
                writeText(templateDetailPath, toJson(templateResult));
                output.templates.push(summarizeTemplate(templateResult, templateDetailName));
            }
            catch (templateError) {
                try {
                    if (app.project) {
                        app.project.close(CloseOptions.DO_NOT_SAVE_CHANGES);
                    }
                }
                catch (closeError) {
                }
                var failedIdentity = templateIdentity(templateConfig);
                output.templates.push({
                    index: failedIdentity.index,
                    name: failedIdentity.name,
                    sourceRelativePath: failedIdentity.sourceRelativePath,
                    sourceFileName: failedIdentity.sourceFileName,
                    sourcePathHash: failedIdentity.sourcePathHash,
                    workingCopyName: failedIdentity.workingCopyName,
                    lengthBytes: failedIdentity.lengthBytes,
                    lastWriteTime: failedIdentity.lastWriteTime,
                    status: 'error',
                    error: String(templateError)
                });
            }
        }
        writeText(config.outputJsonPath, toJson(output));
        writeText(config.statusJsonPath, toJson({
            generatedAt: nowIso(),
            stage: 'ok',
            message: 'AE project parser completed.',
            templateCount: output.templates.length
        }));
    }
    catch (err) {
        try {
            writeText(config.statusJsonPath, toJson({
                generatedAt: nowIso(),
                stage: 'error',
                message: String(err)
            }));
        }
        catch (statusErr) {
        }
        throw err;
    }
    finally {
        try {
            app.endSuppressDialogs(false);
        }
        catch (dialogErr) {
        }
        releaseHostApplication(config);
    }
}());
