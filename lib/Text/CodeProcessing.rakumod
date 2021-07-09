#!/usr/bin/env perl6

# The initial version of the code was taken from : https://stackoverflow.com/a/57128623

use v6;
use Text::CodeProcessing::REPLSandbox;

##===========================================================
## Markdown functions
##===========================================================

#| Markdown code chunk ticks
constant $mdTicks = '```';

#| Markdown code chunk search regex
my regex MarkdownSearch {
    $mdTicks [ '{' \h* $<lang>=('perl6' | 'raku') [\h+ ('evaluate' | 'eval') \h* '=' \h* $<evaluate>=(TRUE | T | FALSE | F) | \h*] '}' | $<lang>=('perl6' | 'raku') ]
    $<code>=[<!before $mdTicks> .]*
    $mdTicks
}

#| Markdown replace sub
sub MarkdownReplace ($sandbox, $/, Str :$evalOutputPrompt = '# ', Str :$evalErrorPrompt = '#ERROR: ', Bool :$promptPerLine = True) {
    $mdTicks ~ $<lang> ~ $<code> ~ $mdTicks ~
            (!$<evaluate> || $<evaluate>.Str (elem) <TRUE T>
                    ?? "\n" ~ $mdTicks ~ "\n" ~ CodeChunkEvaluate($sandbox, $<code>, $evalOutputPrompt, $evalErrorPrompt, :$promptPerLine) ~ $mdTicks
                    !! '');
}


##===========================================================
## Org-mode functions
##===========================================================

constant $orgBeginSrc = '#+BEGIN_SRC';
constant $orgEndSrc = '#+END_SRC';

#| Org-mode code chunk search regex
my regex OrgModeSearch {
    $orgBeginSrc \h* $<lang>=('perl6' | 'raku') $<ccrest>=(\V*) \v
    $<code>=[<!before $orgEndSrc> .]*
    $orgEndSrc
}

#| Org-mode replace sub
sub OrgModeReplace ($sandbox, $/, Str :$evalOutputPrompt = '# ', Str :$evalErrorPrompt = '#ERROR: ', Bool :$promptPerLine = True) {
    $orgBeginSrc ~ ' ' ~ $<lang> ~ $<ccrest> ~ "\n" ~ $<code> ~ $orgEndSrc ~
            "\n" ~ "#+RESULTS:" ~ "\n" ~ CodeChunkEvaluate($sandbox, $<code>, ': ', ':ERROR: ', :$promptPerLine);
}


##===========================================================
## Pod6 functions
##===========================================================

constant $podBeginSrc = '=begin code';
constant $podEndSrc = '=end code';

#| Pod6 code chunk search regex
my regex Pod6Search {
    $podBeginSrc \v
    $<code>=[<!before $podEndSrc> .]*
    $podEndSrc
}

#| Pod6 replace sub
sub Pod6Replace ($sandbox, $/, Str :$evalOutputPrompt = '# ', Str :$evalErrorPrompt = '#ERROR: ', Bool :$promptPerLine = True) {
    $podBeginSrc ~ "\n" ~ $<code> ~ $podEndSrc ~
            "\n" ~ "=begin output" ~ "\n" ~ CodeChunkEvaluate($sandbox, $<code>, $evalOutputPrompt, $evalErrorPrompt, :$promptPerLine) ~ "=end output";
}


##===========================================================
## Dictionaries of file-type => sub
##===========================================================

my %fileTypeToSearchSub =
        markdown => &MarkdownSearch,
        org-mode => &OrgModeSearch,
        pod6 => &Pod6Search;

my %fileTypeToReplaceSub =
        markdown => &MarkdownReplace,
        org-mode => &OrgModeReplace,
        pod6 => &Pod6Replace;


##===========================================================
## Evaluation
##===========================================================

#| Adds a prompt to multi-line text.
sub add-prompt( Str:D $prompt, Str:D $text, Bool :$promptPerLine = True) {
    $prompt ~ ( $promptPerLine ?? $text.subst( "\n", "\n$prompt", :g) !! $text )
}

#| Evaluates a code chunk in a REPL sandbox.
sub CodeChunkEvaluate ($sandbox, $code, $evalOutputPrompt, $evalErrorPrompt, Bool :$promptPerLine = True) is export {

    my $out;

    my $*OUT = $*OUT but role {
        method print (*@args) {
            $out ~= @args
        }
    }

    $sandbox.execution-count++;
    my $p = $sandbox.eval($code.Str, :store($sandbox.execution-count));

    #    say '$p.output : ', $p.output;
    #    say '$p.output-raw : ', $p.output-raw;
    #    say '$p.exception : ', $p.exception;

    ## Result with prompts
    ($p.exception ?? add-prompt($evalErrorPrompt, $p.exception.Str.trim, :$promptPerLine) ~ "\n" !! '') ~
            add-prompt($evalOutputPrompt, ($out // $p.output).trim, :$promptPerLine) ~
            "\n"
}


##===========================================================
## StringCodeChunksEvaluation
##===========================================================

#| Evaluates code chunks in a string.
sub StringCodeChunksEvaluation(Str:D $input,
                               Str:D $docType,
                               Str:D :$evalOutputPrompt = '# ',
                               Str:D :$evalErrorPrompt = '#ERROR: ',
                               Bool :$promptPerLine = True) is export {

    die "The second argument is expected to be one of {%fileTypeToReplaceSub.keys}"
    unless $docType (elem) %fileTypeToReplaceSub.keys;

    ## Create a sandbox
    my $sandbox = Text::CodeProcessing::REPLSandbox.new();

    ## Process code chunks (weave output)
    $input.subst: %fileTypeToSearchSub{$docType}, -> $s { %fileTypeToReplaceSub{$docType}($sandbox, $s,
                                                                                          :$evalOutputPrompt,
                                                                                          :$evalErrorPrompt,
                                                                                          :$promptPerLine) }, :g;
}


##===========================================================
## StringCodeChunksExtraction
##===========================================================

#| Extracts code from code chunks in a string.
sub StringCodeChunksExtraction(Str:D $input,
                               Str:D $docType) is export {

    die "The second argument is expected to be one of {%fileTypeToReplaceSub.keys}"
    unless $docType (elem) %fileTypeToReplaceSub.keys;

    ## Process code chunks (weave output)
    $input.match( %fileTypeToSearchSub{$docType}, :g).map({ trim($_.<code>) }).join("\n")
}


##===========================================================
## FileCodeChunksProcessing
##===========================================================

#| Evaluates code chunks in a file.
sub FileCodeChunksProcessing(Str $fileName,
                             Str :$outputFileName,
                             Str :$evalOutputPrompt = '# ',
                             Str :$evalErrorPrompt = '#ERROR: ',
                             Bool :$noteOutputFileName = False,
                             Bool :$promptPerLine = True,
                             Bool :$tangle = False) {

    ## Determine the output file name and type
    my Str $fileNameNew;
    my Str $fileType;
    my Str $autoSuffix = $tangle ?? '_woven' !! '_tangled';

    with $outputFileName {
        $fileNameNew = $outputFileName
    } else {
        ## If the input file name has extension that is one of <md MD Rmd org pod6>
        ## then insert "_weaved" before the extension.
        if $fileName.match(/ .* \. [md | MD | Rmd | org | pod6] $ /) {
            $fileNameNew = $fileName.subst(/ $<name> = (.*) '.' $<ext> = (md | MD | Rmd | org | pod6) $ /, -> $/ { $<name> ~ $autoSuffix ~ '.' ~ $<ext> });
        } else {
            $fileNameNew = $fileName ~ $autoSuffix;
        }
    }

    if $fileName.match(/ .* \. [md | MD | Rmd] $ /) { $fileType = 'markdown' }
    elsif $fileName.match(/ .* \. org $ /) { $fileType = 'org-mode' }
    elsif $fileName.match(/ .* \. pod6 $ /) { $fileType = 'pod6' }
    else {
        die "Unknown file type (extension). The file type (extension) is expectecd to be one of {<md MD Rmd org pod6>}.";
    }

    if $noteOutputFileName {
        note "Output file is $fileNameNew" unless $outputFileName;
    }

    ## Process code chunks (weave output) and spurt in a file
    if $tangle {
        spurt( $fileNameNew, StringCodeChunksExtraction(slurp($fileName), $fileType) )
    } else {
        spurt( $fileNameNew, StringCodeChunksEvaluation(slurp($fileName), $fileType, :$evalOutputPrompt, :$evalErrorPrompt, :$promptPerLine) )
    }
}


##===========================================================
## FileCodeChunksEvaluation
##===========================================================

#| Evaluates code chunks in a file.
sub FileCodeChunksEvaluation(Str $fileName,
                             Str :$outputFileName,
                             Str :$evalOutputPrompt = '# ',
                             Str :$evalErrorPrompt = '#ERROR: ',
                             Bool :$noteOutputFileName = False,
                             Bool :$promptPerLine = True) is export {

    FileCodeChunksProcessing( $fileName, :$outputFileName, :$evalOutputPrompt, :$evalErrorPrompt, :$noteOutputFileName, :$promptPerLine, :!tangle)
}


##===========================================================
## FileCodeChunksExtraction
##===========================================================

#| Extracts code from code chunks in a file.
sub FileCodeChunksExtraction(Str $fileName,
                             Str :$outputFileName,
                             Bool :$noteOutputFileName = False) is export {

    FileCodeChunksProcessing( $fileName, :$outputFileName, :$noteOutputFileName, :tangle)
}