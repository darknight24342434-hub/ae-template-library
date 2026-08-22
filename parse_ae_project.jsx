#target aftereffects

(function () {
    function nowIso() {
        return new Date().toUTCString();
    }

    function readText(path) {
        var file = File(path);
        file.encoding = 'UTF-8';
        if (!file.open('r')) {
            throw new Error('Could not open for read: ' + path);
        }
        var text = file.read();
        file.close();
        return text;
    }

    function writeText(path, text) {
        var file = File(path);
        file.encoding = 'UTF-8';
        if (!file.open('w')) {
            throw new Error('Could not open for write: ' + path);
        }
        file.write(text);
        file.close();
    }

    function parseJson(text) {
        if (typeof JSON !== 'undefined' && JSON.parse) {
            return JSON.parse(text);
        }
        return eval('(' + text + ')');
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

    function scanCompLayers(comp, templateResult, compInfo, nestedByCompId) {
        for (var layerIndex = 1; layerIndex <= comp.numLayers; layerIndex++) {
            var layer = comp.layer(layerIndex);
            var source = getLayerSource(layer);
            var sourceKind = getSourceKind(source);
            var sourcePath = source instanceof FootageItem ? getFilePath(source) : null;
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
                sourcePath: sourcePath
            };
            compInfo.layers.push(layerInfo);

            var textInfo = readTextLayer(layer);
            if (textInfo) {
                templateResult.textLayers.push({
                    compName: comp.name,
                    layerIndex: layerIndex,
                    layerName: safeName(layer.name),
                    text: textInfo.text,
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
                        sourcePath: sourcePath,
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

    function scanProject(templateConfig) {
        var result = {
            index: templateConfig.index,
            name: templateConfig.name,
            sourcePath: templateConfig.sourcePath,
            workingCopyPath: templateConfig.workingCopyPath,
            lengthBytes: templateConfig.lengthBytes,
            lastWriteTime: templateConfig.lastWriteTime,
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
        var project = app.project;
        var nestedByCompId = {};

        result.project = {
            file: project.file ? project.file.fsName : null,
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
                var filePath = getFilePath(item);
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
                    filePath: filePath,
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
                    layers: []
                };
                scanCompLayers(item, result, compInfo, nestedByCompId);
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
            possibleRenderCompCount: result.possibleRenderComps.length
        };
        result.status = 'parsed';
        app.project.close(CloseOptions.DO_NOT_SAVE_CHANGES);
        return result;
    }

    var configPath = $.global.AE_TEMPLATE_PARSE_CONFIG;
    if (!configPath) {
        throw new Error('AE_TEMPLATE_PARSE_CONFIG was not set by the runner wrapper.');
    }

    var config = parseJson(readText(configPath));
    var output = {
        schemaVersion: 1,
        generatedAt: nowIso(),
        materialRoot: config.materialRoot,
        runDir: config.runDir,
        templates: []
    };

    try {
        app.beginSuppressDialogs();
        for (var i = 0; i < config.templates.length; i++) {
            var templateConfig = config.templates[i];
            try {
                output.templates.push(scanProject(templateConfig));
            }
            catch (templateError) {
                try {
                    if (app.project) {
                        app.project.close(CloseOptions.DO_NOT_SAVE_CHANGES);
                    }
                }
                catch (closeError) {
                }
                output.templates.push({
                    index: templateConfig.index,
                    name: templateConfig.name,
                    sourcePath: templateConfig.sourcePath,
                    workingCopyPath: templateConfig.workingCopyPath,
                    lengthBytes: templateConfig.lengthBytes,
                    lastWriteTime: templateConfig.lastWriteTime,
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
        try {
            app.quit();
        }
        catch (quitErr) {
        }
    }
}());
