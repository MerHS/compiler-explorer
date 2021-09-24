import path from 'path';

import fs from 'fs-extra';
import _ from 'underscore';

import { BaseCompiler } from '../base-compiler';
import { logger } from '../logger';
import * as utils from '../utils';

export class MLIRTVCompiler extends BaseCompiler {
    static get key() { return 'mlir-tv'; }

    // eslint-disable-next-line no-unused-vars
    optionsForFilter(filters, outputFilename) {
        return [];
    }

    preProcess(source, filters) {
        if (filters.binary && !new RegExp(this.compilerProps('stubRe')).test(source)) {
            source += '\n' + this.compilerProps('stubText') + '\n';
        }
        return source;
    }

    async compile(source, options, backendOptions, filters, bypassCache, tools, executionParameters, libraries, files) {
        const optionsError = this.checkOptions(options);
        if (optionsError) throw optionsError;
        const sourceError = this.checkSource(source);
        if (sourceError) throw sourceError;

        const libsAndOptions = {libraries, options};
        if (this.tryAutodetectLibraries(libsAndOptions)) {
            libraries = libsAndOptions.libraries;
            options = libsAndOptions.options;
        }

        // Don't run binary for unsupported compilers, even if we're asked.
        if (filters.binary && !this.compiler.supportsBinary) {
            delete filters.binary;
        }
        const executeParameters = {
            args: executionParameters.args || [],
            stdin: executionParameters.stdin || '',
        };
        const key = this.getCacheKey(source, options, backendOptions, filters, tools, libraries, files);

        const doExecute = filters.execute;
        filters = Object.assign({}, filters);
        filters.execute = false;

        if (!bypassCache) {
            const cacheRetreiveTimeStart = process.hrtime.bigint();
            const result = await this.env.cacheGet(key);
            if (result) {
                const cacheRetreiveTimeEnd = process.hrtime.bigint();
                result.retreivedFromCacheTime = ((cacheRetreiveTimeEnd - cacheRetreiveTimeStart) /
                    BigInt(1000000)).toString();
                result.retreivedFromCache = true;
                if (doExecute) {
                    result.execResult = await this.env.enqueue(async () => {
                        return this.handleExecution(key, executeParameters);
                    });

                    if (result.execResult && result.execResult.buildResult) {
                        this.doTempfolderCleanup(result.execResult.buildResult);
                    }
                }
                return result;
            }
        }

        return this.env.enqueue(async () => {
            let subSource = '';
            source = this.preProcess(source, filters);
            if (backendOptions.subSource) {
                subSource = this.preProcess(backendOptions.subSource, filters);
            }

            if (backendOptions.executorRequest) {
                const execResult = await this.handleExecution(key, executeParameters);
                if (execResult.buildResult) {
                    this.doTempfolderCleanup(execResult.buildResult);
                }
                return execResult;
            }

            const dirPath = await this.newTempDir();

            const inputFilename = await this.writeTwoSources(dirPath, source, subSource, files, filters);

            const [result, optOutput] = await this.doCompilation(
                inputFilename, dirPath, key, options, filters, backendOptions, libraries, tools);

            return await this.afterCompilation(result, doExecute, key, executeParameters, tools, backendOptions,
                filters, options, optOutput);
        });
    }

    async doCompilation(inputFilename, dirPath, key, options, filters, backendOptions, libraries, tools) {
        let buildEnvironment = Promise.resolve();
        if (filters.binary) {
            buildEnvironment = this.setupBuildEnvironment(key, dirPath);
        }

        const inputFilenameSafe = this.filename(inputFilename);

        const outputFilename = this.getOutputFilename(dirPath, this.outputFilebase, key);

        options = _.compact(
            this.prepareArguments(options, filters, backendOptions, inputFilename, outputFilename, libraries),
        );

        const execOptions = this.getDefaultExecOptions();
        execOptions.ldPath = this.getSharedLibraryPathsAsLdLibraryPaths([]);

        const downloads = await buildEnvironment;
        const [asmResult, toolsResult] = await Promise.all([
            this.runCompiler(this.compiler.exe, options, inputFilenameSafe, execOptions),
            Promise.all(this.runToolsOfType(tools, 'independent', this.getCompilationInfo(key, {
                inputFilename,
                dirPath,
                outputFilename,
            }))),
        ]);
        asmResult.dirPath = dirPath;
        asmResult.compilationOptions = options;
        asmResult.downloads = downloads;

        asmResult.tools = toolsResult;

        return this.checkOutputFileAndDoPostProcess(asmResult, outputFilename, filters);
    }

    prepareArguments(userOptions, filters, backendOptions, inputFilename, outputFilename, libraries) {
        let options = this.optionsForFilter(filters, outputFilename, userOptions);
        backendOptions = backendOptions || {};

        if (this.compiler.options) {
            options = options.concat(utils.splitArguments(this.compiler.options));
        }

        if (this.compiler.supportsOptOutput && backendOptions.produceOptInfo) {
            options = options.concat(this.compiler.optArg);
        }

        const libIncludes = this.getIncludeArguments(libraries);
        const libOptions = this.getLibraryOptions(libraries);
        const subFilename = this.subFilename(inputFilename);
        let libLinks = [];
        let libPaths = [];
        let staticLibLinks = [];

        if (filters.binary) {
            libLinks = this.getSharedLibraryLinks(libraries);
            libPaths = this.getSharedLibraryPathsAsArguments(libraries);
            staticLibLinks = this.getStaticLibraryLinks(libraries);
        }

        userOptions = this.filterUserOptions(userOptions) || [];
        return options.concat(libIncludes, libOptions, libPaths, libLinks, userOptions,
            [this.filename(inputFilename), this.filename(subFilename)], staticLibLinks);
    }

    async writeTwoSources(dirPath, source, subSource, files, filters) {
        const inputFilename = path.join(dirPath, this.compileFilename);
        const subFilename = this.subFilename(inputFilename);
        await fs.writeFile(inputFilename, source);
        await fs.writeFile(subFilename, subSource);

        if (files) {
            filters.dontMaskFilenames = true;

            await this.writeMultipleFiles(files, dirPath);
        }

        return inputFilename;
    }

    doTempfolderCleanup(buildResult) {
        if (buildResult.dirPath && !this.delayCleanupTemp) {
            //fs.remove(buildResult.dirPath);
            logger.debug(`removed ${buildResult.dirPath}`);
        }
        buildResult.dirPath = undefined;
    }

    subFilename(inputFilename) {
        return `${inputFilename}_tgt`;
    }

    async runCompiler(compiler, options, inputFilename, execOptions) {
        if (!execOptions) {
            execOptions = this.getDefaultExecOptions();
        }

        if (!execOptions.customCwd) {
            execOptions.customCwd = path.dirname(inputFilename);
        }

        const result = await this.exec(compiler, options, execOptions);
        result.inputFilename = inputFilename;
        const transformedInput = result.filenameTransform(inputFilename);
        result.rawStdout = result.stdout;
        result.rawStderr = result.stderr;
        this.parseCompilationOutput(result, transformedInput);
        return result;
    }

    async postProcess(result, outputFilename, filters) {
        const postProcess = _.compact(this.compiler.postProcess);
        const maxSize = this.env.ceProps('max-asm-size', 64 * 1024 * 1024);
        const optPromise = result.hasOptOutput ? this.processOptOutput(result.optPath) : '';
        const asmPromise = (filters.binary && this.supportsObjdump())
            ? this.objdump(outputFilename, result, maxSize, filters.intel, filters.demangle)
            : (async () => {
                if (postProcess.length > 0) {
                    return this.execPostProcess(result, postProcess, outputFilename, maxSize);
                } else {
                    // const contents = await fs.readFile(outputFilename);
                    result.asm = `<stdout>\n${result.rawStdout}\n<stderr>\n${
                        result.rawStderr
                    }\n<exit code: ${result.code}>\n`;

                    // force code 0
                    result.code = 0;
                    return result;
                }
            })();
        return Promise.all([asmPromise, optPromise]);
    }
}
