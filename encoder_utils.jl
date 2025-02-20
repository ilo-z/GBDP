# using Distributions, Random ??

global tagrepsize = 32 # Size of the randomly initialized column vectors that represents features such that xpostag, upostag, feats

function fillwvecs!(sentences, isents, wembed; GPUFEATS=false)
    for (s, isents) in zip(sentences, isents)
        empty!(s.wvec)
        for w in isents
            if GPUFEATS
                push!(s.wvec, wembed[:, w])
            else
                push!(s.wvec, Array(wembed[:, w]))
            end
        end
    end
end


function fillcvecs!(sentences, forw, back; GPUFEATS=false)
    T = length(forw)
    for i in 1:length(sentences)
        s = sentences[i]
        empty!(s.fvec)
        empty!(s.bvec)
        N = length(s)
        for n in 1:N
            t = T-N+n
            if GPUFEATS #GPU
                push!(s.fvec, forw[t][:,i])
                push!(s.bvec, back[t][:,i])
            else #CPU
                push!(s.fvec, Array(forw[t][:,i]))
                push!(s.bvec, Array(back[t][:,i]))
            end
        end
    end
end


function lmloss(model, data, mask, forw, back; result=nothing)
    T = length(data)
    B = length(data[1])
    weight, bias = wsoft(model), bsoft(model)
    idx(t,b,n) = data[t][b] + (b-1)*n

    total = count = 0
    for t in 1:T
        ypred = weight * vcat(forw[t], back[t]) .+ bias
        nrows,ncols = size(ypred)
        index = Int[]
        for b=1:B
            if mask[t][b]==1
                push!(index, idx(t,b,nrows))
            end
        end
        o1 = logp(ypred, dims=1)
        o2 = o1[index]
        total += sum(o2)
        count += length(o2)
    end
    
    if result != nothing
        result[1] += AutoGrad.getval(total)
        result[2] += count
    end
    return total
end


function wordlstm(model, data, mask, embeddings)
    weight, bias = wforw(model), bforw(model)
    T = length(data)
    B = length(data[1])
    H = div(length(bias), 4)


    if isa(weight, KnetArray)
        mask = map(KnetArray, mask)
    end
    
    wzero = fill!(similar(bias, H, B), 0)

    # forward lstm
    hidden = cell = wzero
    fhiddens = Array{Any}(undef,T-2)  # fhiddens = Array(Any, T-2) : deprecated
    for t in 1:T-2
        (hidden, cell) = _lstm(weight, bias, hidden, cell, embeddings[:, data[t]]; mask=mask[t])
        fhiddens[t] = hidden
    end

    # backward lstm
    weight_b, bias_b = wback(model), bback(model)
    hidden = cell = wzero
    bhiddens = Array{Any}(undef,T-2)  # bhiddens = Array(Any, T-2) : deprecated
    for t in T:-1:3
        (hidden, cell) = _lstm(weight_b, bias_b, hidden, cell, embeddings[:, data[t]]; mask=mask[t])
        bhiddens[t-2] = hidden
    end
    return fhiddens, bhiddens
end


function charlstm(model, data, mask)
    weight, bias, embeddings = wchar(model), bchar(model), cembed(model)
    T = length(data)
    B = length(data[1])
    H = div(length(bias), 4)

    
    if isa(weight, KnetArray)
        mask = map(KnetArray, mask)
    end
    
    czero = fill!(similar(bias, H, B), 0)
    hidden = cell = czero
    for t in 1:T
        (hidden, cell) = _lstm(weight, bias, hidden, cell, embeddings[:, data[t]]; mask=mask[t])
    end
    return hidden
end


function _lstm(weight, bias, hidden, cell, input; mask=nothing)
    gates = weight * vcat(input, hidden) .+ bias
    H = size(hidden, 1)
    forget = sigm.(gates[1:H, :])
    ingate = sigm.(gates[1+H:2H, :])
    outgate = sigm.(gates[1+2H:3H, :])
    change = tanh.(gates[1+3H:4H, :])
    (mask != nothing) && (mask = reshape(mask, 1, length(mask)))

    cell = cell .* forget + ingate .* change
    hidden = outgate .* tanh.(cell)
    if mask != nothing
        hidden = hidden .* mask
        cell = cell .* mask
    end
    return (hidden, cell)
end


function goldbatch(sentences, maxlen, wdict, unkwid, pad=unkwid)
    B = length(sentences)
    T = maxlen
    data = [ Array{Int}(undef,B) for t in 1:T ]
    mask = [ Array{Float32}(undef,B) for t in 1:T ]
    for t in 1:T
        for b in 1:B
            N = length(sentences[b])
            n = t - T + N
            if n <= 0
                mask[t][b] = 0
                data[t][b] = pad
            else
                mask[t][b] = 1
                data[t][b] = get(wdict, sentences[b].word[n], unkwid)
            end
        end
    end
    return data, mask
end


function tokenbatch(words, maxlen, sos, eos, pad=eos)
    B = length(words) # batchsize
    T = maxlen + 2
    data = [ Array{Int}(undef,B) for t in 1:T ]
    mask = [ Array{Float32}(undef,B) for t in 1:T ]
    @inbounds for t in 1:T
        for b in 1:B
            N = length(words[b]) # wordlen
            n = t - T + N + 1 # cursor 
            if n < 0
                mask[t][b] = 0
                data[t][b] = pad
            else
                mask[t][b] = 1
                if n == 0
                    data[t][b] = sos
                elseif n <= N
                    data[t][b] = words[b][n]
                elseif n == N+1
                    data[t][b] = eos
                else
                    error()
                end
            end
        end
    end
    return data, mask
end


function maptoint(sentences, v::Vocab)
    MAXWORD = 32
    wdict = empty!(v.idict) # it is already empty ?
    cdict = v.cdict
    unkcid = cdict[v.unkchar]
    words = Vector{Int}[]
    sents = Vector{Int}[]

    maxwordlen = 0; maxsentlen = 0;
    for w in (v.sosword, v.eosword)
        wid = get!(wdict, w, 1+length(wdict))
        word = Array{Int}(undef,length(w)) #Array(Int, length(w))
        wordi = 0 # to check 2 byte characters
        for c in w
            word[wordi+=1] = get(cdict, c, unkcid)
        end
        (wordi != length(w)) && error("Missing in single word process")
        (wordi > maxwordlen) && (maxwordlen = wordi)
        push!(words, word)
    end

    for s in sentences
        sent = Array{Int}(undef,length(s.word)) #Array(Int, length(s.word))
        senti = 0
        for w in s.word
            ndict = length(wdict)
            wid = get!(wdict, w, 1+ndict)
            sent[senti+=1] = wid
            if wid == 1+ndict
                word = Array{Int}(undef,length(w)) #Array(Int, length(w))
                wordi = 0
                for c in w
                    word[wordi+=1] = get(cdict, c, unkcid)
                end
                (wordi != length(w)) && error("Missing in single word process")
                if wordi > MAXWORD; wordi=MAXWORD; word = word[1:wordi]; end;
                (wordi > maxwordlen) && (maxwordlen = wordi) 
                push!(words, word)
            end
        end
        @assert(senti == length(s.word))
        (senti > maxsentlen) && (maxsentlen = senti)
        push!(sents, sent)
    end
    @assert(length(wdict) == length(words))
    return words, sents, maxwordlen, maxsentlen
end


makewmodel1(d)=[ d["cembed"],
                 d["char"][1],
                 d["char"][2],
                 d["forw"][1],
                 d["forw"][2],
                 d["back"][1],
                 d["back"][2],
                 d["soft"][1],
                 d["soft"][2] ]


function makewmodel(d)
    d1 = makewmodel1(d)
    if gpu() >= 0
        return map(KnetArray, d1)
    else
        return map(Array, d1)
    end
end


cembed(m) = m[1]
wchar(m) = m[2]; bchar(m) = m[3];
wforw(m) = m[4]; bforw(m) = m[5];
wback(m) = m[6]; bback(m) = m[7];
wsoft(m) = m[8]; bsoft(m) = m[9];


function fillvecs!(wmodel, sentences, vocab, fs; batchsize=128)

    words, sents, maxwordlen, maxsentlen = maptoint(sentences, vocab)
    sow = vocab.cdict[vocab.sowchar]
    eow = vocab.cdict[vocab.eowchar]
    paw = vocab.cdict[vocab.unkchar]
 
    # word-embeddings calcutation
    wembed = Any[]
    #free_KnetArray();
    for i=1:batchsize:length(words)
        j = min(i+batchsize-1,length(words))
        wij = view(words,i:j)
        maxij = maximum(map(length, wij))
        cdata, cmask = tokenbatch(wij, maxij, sow, eow)
        push!(wembed, charlstm(wmodel, cdata, cmask))
    end
    wembed =hcat(wembed...)
    fillwvecs!(sentences, sents, wembed)

    # extended word embeddings with xpos, upos and feats
    extended_wembed = extend_wembeddings(v, fs, sentences, sents, wembed)
    
    
    sos,eos,unk = vocab.idict[vocab.sosword], vocab.idict[vocab.eosword], vocab.odict[vocab.unkword]
    result = zeros(2)
    #free_KnetArray()
    for i=1:batchsize:length(sents)
        j = min(i+batchsize-1, length(sents))
        isentij = view(sents, i:j)
        maxij = maximum(map(length, isentij))
        wdata, wmask = tokenbatch(isentij, maxij, sos, eos)
        forw, back = mywordlstm(wmodel, wdata, wmask, extended_wembed)
        sentij = view(sentences, i:j)
        fillcvecs!(sentij, forw, back)
        odata, omask = goldbatch(sentij, maxij, vocab.odict, unk)
        lmloss(wmodel,odata,omask,forw,back; result=result) 
    end
    # return extended_wembed, wdata, wmask
end


# Things we added

# Pad the feature vector (s.cavec) so that size of all feature vectors are 960
function padfeatvec!(corpus) # used in demo, no longer used
    for s in corpus
        for c in 1:length(s.cavec)
            while length(s.cavec[c]) < 965
                push!(s.cavec[c],0)
            end
        end
    end
end


# Creates column vectors for all unique xpostags, postags, and features; acts like a vocab, extendedvocab
function createcolvecs(corpus,ev)
    dist = Normal()
    xpostags = rand(dist, (tagrepsize, length(keys(ev.xpostags))))
    postags = rand(dist, (tagrepsize, length(keys(ev.vocab.postags))))
    feats = rand(dist, (tagrepsize, length(keys(ev.feats))))
    deprels = rand(dist, (tagrepsize*100, length(keys(ev.vocab.deprels))))
    return FeatureSource(postags,xpostags,feats,deprels)
end

# fs: feature source, feats: features of a word, s.feats[i]
function sumfeats(feats, fs)
    sum = zeros(length(fs.feats[:,1]))
    for i in 1:length(feats)
        sum .+= fs.feats[:,feats[i]]
    end
    return sum
end

# Version where we concat xpostag, postag, feats after creating fvec, bvec
function createfeatvec!(corpus, fs)
    for sent in corpus
        for i in 1:length(sent)
            push!(sent.cavec, vcat(sent.wvec[i], sent.fvec[i], sent.bvec[i], fs.postags[:,sent.postag[i]], fs.xpostags[:,sent.xpostag[i]], sumfeats(sent.feats[i],fs)))
        end
    end
end


function fillcavec!(corpus)
    for sent in corpus
        for i in 1:length(sent)
            push!(sent.cavec, KnetArray(map(Float32,vcat(sent.wvec[i], sent.fvec[i], sent.bvec[i]))))
        end
    end
end

function extend_wembeddings(v, fs, corpus, sents, wembed) # v: Vocab, fs: feature source, sents: maptoint output-int represented sentences, 
    wembed_extension = Any[]
    dist = Normal() # to initialize eosword, sosword randomly
    id = 1

    for w in (v.sosword, v.eosword)
        kw = map(Float32,rand(dist, tagrepsize*3))
        push!(wembed_extension, KnetArray(kw)) # 3 because 3*32 = xpostag, upostag, featssum
        id += 1
    end
    
    for (s, is) in zip(corpus, sents) # iterate sentences
        for i in 1:length(s.word) # iterate each word in a sentence
            if id == is[i]
                push!(wembed_extension, KnetArray(map(Float32,vcat(fs.postags[:,s.postag[i]], fs.xpostags[:,s.xpostag[i]], sumfeats(s.feats[i],fs)))))
                id += 1
            end
        end
    end
    
        extended_wembed = vcat(wembed,hcat(wembed_extension...)) # concat version(446X13808) = wembed + wembed_extension(postag,xpostag,feat)
    return vcat(extended_wembed...)
end

function mywordlstm(model, data, mask, embeddings)
    weight, bias = wforw(model), bforw(model)
    T = length(data)
    B = length(data[1])
    H = div(length(bias), 4)

    if isa(weight, KnetArray)
        mask = map(KnetArray, mask)
    end
    
    wzero = fill!(similar(bias, H, B), 0)

    # forward lstm
    hidden = cell = wzero
    fhiddens = Array{Any}(undef,T-2)  # fhiddens = Array(Any, T-2) : deprecated
    
    dist = Normal()
    difference = size(embeddings,1)+size(hidden,1)-size(weight,2)
    extweight = hcat(weight, KnetArray(map(Float32,rand(dist, (size(weight,1), difference))))) # extend pretrained model weights with randomly initalized weights for xpos, upos, feat
    # number of the weigths are decided by subtracting (column)number of pretrained model weights from (row) number of extended wembeddings (which is equal to 96 since 3 x 32 as of now)

    
    for t in 1:T-2
        (hidden, cell) = _lstm(extweight, bias, hidden, cell, embeddings[:, data[t]]; mask=mask[t])
        fhiddens[t] = hidden
    end

    # backward lstm
    weight_b, bias_b = wback(model), bback(model)

    hidden = cell = wzero
    bhiddens = Array{Any}(undef,T-2)  # bhiddens = Array(Any, T-2) : deprecated

    difference_b = size(embeddings,1)+size(hidden,1)-size(weight_b,2) # 746 - ()
    extweight_b = hcat(weight_b, KnetArray(map(Float32,rand(dist, (size(weight_b,1), difference_b)))))
    
    for t in T:-1:3
        (hidden, cell) = _lstm(extweight_b, bias_b, hidden, cell, embeddings[:, data[t]]; mask=mask[t])
        bhiddens[t-2] = hidden
    end
    return fhiddens, bhiddens
end